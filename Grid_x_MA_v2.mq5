//+------------------------------------------------------------------+
//|                                          Grid x MA.mq5           |
//|                                      Professional Grid Trading EA |
//|                              Copyright 2025, Professional Trader |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Professional Trader"
#property link      "https://www.facebook.com/kouy.somchanmavong.77"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

enum ENUM_TRADE_DIRECTION { TRADE_BUY_ONLY, TRADE_SELL_ONLY, TRADE_BUY_AND_SELL };
enum ENUM_EA_STATE        { STATE_ACTIVE, STATE_COOLDOWN, STATE_RECOVERY, STATE_DAILY_LIMIT };
enum ENUM_GRID_MODE       { MODE_GRID, MODE_TREND_RECOVERY };

#define MAGIC_NUMBER  123456
#define TRADE_COMMENT "GridEA"
#define MA_METHOD     MODE_EMA
#define MA_PRICE      PRICE_CLOSE
#define UseMASignal   true
#define MAX_SLOTS     200

input group "=== MA FILTER SETTINGS ==="
input int      MAPeriod                = 81;

input group "=== TRADE DIRECTION ==="
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_BUY_AND_SELL;

input group "=== GRID MODE ==="
input ENUM_GRID_MODE GridMode          = MODE_GRID;

input group "=== GRID PARAMETERS ==="
input double   LotSize                 = 0.05;
input double   LotStep                 = 0.01;
input int      GridStepPoints          = 250;
input int      TakeProfitPoints        = 300;
input int      MaxOrders               = 100;

input group "=== TAKE PROFIT BASKET % ==="
input bool     UseBasketTPPercent      = true;           // Enable basket TP by equity %
input double   BasketTPPercent         = 0.05;           // Basket TP % of balance (0.05 = 0.05%)

input group "=== DAILY PROFIT LIMIT ==="
input bool     UseDailyProfitLimit     = true;           // Enable daily profit limit
input double   DailyProfitPercent      = 5.0;           // Daily profit limit % of starting balance

input group "=== TRADE TIME FILTER ==="
input bool     UseTradeTimeFilter      = true;           // Enable trade time filter
input int      TradeStartHour          = 7;              // Trade start hour (server time)
input int      TradeStartMinute        = 0;              // Trade start minute
input int      TradeEndHour            = 23;             // Trade end hour (server time)
input int      TradeEndMinute          = 0;              // Trade end minute

input group "=== COOLDOWN TIME FILTER ==="
input bool     UseCooldownTimeFilter   = true;           // Enable cooldown during specific hours
input int      CooldownFilterStartHour = 7;              // Cooldown window start hour
input int      CooldownFilterStartMin  = 0;              // Cooldown window start minute
input int      CooldownFilterEndHour   = 13;             // Cooldown window end hour
input int      CooldownFilterEndMin    = 0;              // Cooldown window end minute
input int      PostWindowCooldownMin   = 10;             // Cooldown minutes AFTER window ends

input group "=== RISK MANAGEMENT ==="
input double   RecoveryEquityThreshold = 0.0;
input int      CooldownMinutes         = 0;

CTrade        trade;
CPositionInfo position;
CAccountInfo  account;
CSymbolInfo   m_symbol;

ENUM_EA_STATE      currentState          = STATE_ACTIVE;
datetime           cooldownEndTime       = 0;
double             initialBalance        = 0;
int                maHandle              = INVALID_HANDLE;
double             maBuffer[];
datetime           lastBuyGridTime       = 0;
datetime           lastSellGridTime      = 0;

ENUM_POSITION_TYPE trCurrentTrend        = POSITION_TYPE_BUY;
bool               trInitialized         = false;

//--- Slot tracking arrays
bool buySlotFilled[MAX_SLOTS];
bool sellSlotFilled[MAX_SLOTS];
double buyAnchor  = 0;
double sellAnchor = 0;

//--- Daily profit tracking
double   dailyStartBalance   = 0;
datetime dailyResetDate      = 0;

//--- Cooldown time filter state
bool     inCooldownWindow      = false;   // true while inside cooldown filter hours
bool     postWindowCooldownSet = false;   // true once post-window cooldown is triggered

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
int TimeToMinutes(int hour, int minute) { return hour * 60 + minute; }

int CurrentTimeMinutes()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
}

//--- Returns true if current server time is inside [startH:startM , endH:endM)
bool IsTimeInRange(int startH, int startM, int endH, int endM)
{
   int cur   = CurrentTimeMinutes();
   int start = TimeToMinutes(startH, startM);
   int end   = TimeToMinutes(endH,   endM);

   if(start <= end)
      return (cur >= start && cur < end);
   else // overnight range (e.g. 22:00 – 06:00)
      return (cur >= start || cur < end);
}

//+------------------------------------------------------------------+
//| Daily profit tracking                                            |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   if(dailyResetDate != today)
   {
      dailyResetDate    = today;
      dailyStartBalance = account.Balance();
      //--- Reset daily-limit state so trading can resume on a new day
      if(currentState == STATE_DAILY_LIMIT) currentState = STATE_ACTIVE;
      Print("Daily reset — starting balance: ", DoubleToString(dailyStartBalance, 2));
   }
}

bool IsDailyProfitLimitReached()
{
   if(!UseDailyProfitLimit || dailyStartBalance <= 0) return false;
   double todayProfit = account.Balance() - dailyStartBalance;
   double limitAmount = dailyStartBalance * DailyProfitPercent / 100.0;
   return (todayProfit >= limitAmount);
}

//+------------------------------------------------------------------+
//| Basket take-profit by % of balance                               |
//+------------------------------------------------------------------+
bool CheckBasketTPPercent(ENUM_POSITION_TYPE side)
{
   if(!UseBasketTPPercent) return false;
   double bal = account.Balance();
   if(bal <= 0) return false;

   double targetProfit = bal * BasketTPPercent / 100.0;
   double floatingPnL  = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER
            && position.PositionType() == side)
            floatingPnL += position.Profit() + position.Swap() + position.Commission();

   return (floatingPnL >= targetProfit);
}

bool CheckBasketTPPercentAll()
{
   if(!UseBasketTPPercent) return false;
   double bal = account.Balance();
   if(bal <= 0) return false;

   double targetProfit = bal * BasketTPPercent / 100.0;
   double floatingPnL  = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER)
            floatingPnL += position.Profit() + position.Swap() + position.Commission();

   return (floatingPnL >= targetProfit);
}

//+------------------------------------------------------------------+
//| Reset slot tracking for one side                                 |
//+------------------------------------------------------------------+
void ResetSlots(ENUM_POSITION_TYPE side)
{
   if(side == POSITION_TYPE_BUY)
   {
      buyAnchor = 0;
      for(int i = 0; i < MAX_SLOTS; i++) buySlotFilled[i] = false;
   }
   else
   {
      sellAnchor = 0;
      for(int i = 0; i < MAX_SLOTS; i++) sellSlotFilled[i] = false;
   }
}

void MarkSlot(ENUM_POSITION_TYPE side, int slot)
{
   if(slot < 1 || slot >= MAX_SLOTS) return;
   if(side == POSITION_TYPE_BUY)  buySlotFilled[slot]  = true;
   else                           sellSlotFilled[slot] = true;
}

bool IsSlotFilled(ENUM_POSITION_TYPE side, int slot)
{
   if(slot < 1 || slot >= MAX_SLOTS) return true;
   if(side == POSITION_TYPE_BUY)  return buySlotFilled[slot];
   else                           return sellSlotFilled[slot];
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!m_symbol.Name(_Symbol))
   {
      Print("Failed to initialize symbol");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MAGIC_NUMBER);

   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   Print("Account margin mode: ", marginMode,
         " | Hedging: ", (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING),
         " | GridStep: ", GridStepPoints, " x ", m_symbol.Point(),
         " = ", GridStepPoints * m_symbol.Point());

   if(UseMASignal)
   {
      maHandle = iMA(_Symbol, _Period, MAPeriod, 0, MA_METHOD, MA_PRICE);
      if(maHandle == INVALID_HANDLE)
      {
         Print("Failed to create MA indicator");
         return(INIT_FAILED);
      }
      ArraySetAsSeries(maBuffer, true);
   }

   initialBalance      = account.Balance();
   dailyStartBalance   = initialBalance;
   trInitialized       = false;
   inCooldownWindow    = false;
   postWindowCooldownSet = false;

   ResetSlots(POSITION_TYPE_BUY);
   ResetSlots(POSITION_TYPE_SELL);

   //--- Initialise daily date
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dailyResetDate = (datetime)StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   RebuildSlotState();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Rebuild slot tracking from open positions on attach/restart      |
//+------------------------------------------------------------------+
void RebuildSlotState()
{
   ResetSlots(POSITION_TYPE_BUY);
   ResetSlots(POSITION_TYPE_SELL);

   datetime earliestBuy  = (datetime)INT_MAX;
   datetime earliestSell = (datetime)INT_MAX;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Symbol() != _Symbol || position.Magic() != MAGIC_NUMBER) continue;
         if(position.PositionType() == POSITION_TYPE_BUY  && position.Time() < earliestBuy)
         {
            earliestBuy = position.Time();
            buyAnchor   = position.PriceOpen();
         }
         if(position.PositionType() == POSITION_TYPE_SELL && position.Time() < earliestSell)
         {
            earliestSell = position.Time();
            sellAnchor   = position.PriceOpen();
         }
      }
   }

   double gridStep = GridStepPoints * m_symbol.Point();
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(position.SelectByIndex(i))
      {
         if(position.Symbol() != _Symbol || position.Magic() != MAGIC_NUMBER) continue;

         ENUM_POSITION_TYPE side   = position.PositionType();
         double             anchor = (side == POSITION_TYPE_BUY) ? buyAnchor : sellAnchor;
         if(anchor == 0) continue;

         double dist = (side == POSITION_TYPE_BUY)
                       ? anchor - position.PriceOpen()
                       : position.PriceOpen() - anchor;

         int slot = (int)MathRound(dist / gridStep);
         if(slot >= 1 && slot < MAX_SLOTS) MarkSlot(side, slot);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(maHandle != INVALID_HANDLE) IndicatorRelease(maHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!m_symbol.RefreshRates()) return;

   //--- Daily housekeeping
   CheckDailyReset();

   //--- Check daily profit limit
   if(UseDailyProfitLimit && IsDailyProfitLimitReached())
   {
      if(currentState != STATE_DAILY_LIMIT)
      {
         currentState = STATE_DAILY_LIMIT;
         Print("Daily profit limit reached (",
               DoubleToString(DailyProfitPercent, 2),
               "%) — trading paused until next day.");
      }
      return; // no new trades; existing positions are managed passively
   }

   //--- Cooldown time-filter management (7:00–13:00 window)
   HandleCooldownTimeFilter();

   CheckRecoveryMode();
   CheckCooldown();

   if(currentState != STATE_ACTIVE) return;

   //--- Trade time filter: block NEW entries outside allowed window
   if(UseTradeTimeFilter && !IsTimeInRange(TradeStartHour, TradeStartMinute,
                                           TradeEndHour,   TradeEndMinute))
   {
      //--- Allow existing positions to be managed (TP checks) but no new entries
      if(GridMode == MODE_TREND_RECOVERY)
         ManageExistingOnly();
      else
      {
         if(CheckTakeProfit() || CheckBasketTPPercentAll())
         {
            CloseAllPositions();
            ResetSlots(POSITION_TYPE_BUY);
            ResetSlots(POSITION_TYPE_SELL);
            if(CooldownMinutes > 0) EnterCooldown();
         }
      }
      return;
   }

   //--- Normal flow
   if(GridMode == MODE_TREND_RECOVERY)
   {
      RunTrendRecoveryMode();
      return;
   }

   //--- Check TP (points-based OR basket %)
   if(CheckTakeProfit() || CheckBasketTPPercentAll())
   {
      CloseAllPositions();
      ResetSlots(POSITION_TYPE_BUY);
      ResetSlots(POSITION_TYPE_SELL);
      if(CooldownMinutes > 0) EnterCooldown();
      return;
   }

   if(CountPositions() == 0)
      OpenFirstPosition();
   else
      CheckGridEntry();
}

//+------------------------------------------------------------------+
//| Manage only TP on existing positions (no new entries)            |
//+------------------------------------------------------------------+
void ManageExistingOnly()
{
   if(CheckTakeProfit() || CheckBasketTPPercentAll())
   {
      CloseAllPositions();
      ResetSlots(POSITION_TYPE_BUY);
      ResetSlots(POSITION_TYPE_SELL);
      if(CooldownMinutes > 0) EnterCooldown();
   }
}

//+------------------------------------------------------------------+
//| Cooldown time-filter: block trading during 7:00–13:00,          |
//|   then apply PostWindowCooldownMin after window closes.          |
//+------------------------------------------------------------------+
void HandleCooldownTimeFilter()
{
   if(!UseCooldownTimeFilter) return;

   bool nowInWindow = IsTimeInRange(CooldownFilterStartHour, CooldownFilterStartMin,
                                    CooldownFilterEndHour,   CooldownFilterEndMin);

   if(nowInWindow)
   {
      //--- Entered or staying in the cooldown window
      if(!inCooldownWindow)
      {
         inCooldownWindow      = true;
         postWindowCooldownSet = false;       // reset for when window ends
         if(currentState == STATE_ACTIVE)
         {
            currentState    = STATE_COOLDOWN;
            cooldownEndTime = (datetime)INT_MAX; // hold until window exits
            Print("Cooldown time filter active (",
                  CooldownFilterStartHour, ":", StringFormat("%02d", CooldownFilterStartMin),
                  " – ",
                  CooldownFilterEndHour, ":", StringFormat("%02d", CooldownFilterEndMin), ")");
         }
      }
   }
   else
   {
      //--- Outside the cooldown window
      if(inCooldownWindow)
      {
         //--- Just exited the window — apply post-window cooldown
         inCooldownWindow = false;
         if(!postWindowCooldownSet)
         {
            postWindowCooldownSet = true;
            if(PostWindowCooldownMin > 0)
            {
               currentState    = STATE_COOLDOWN;
               cooldownEndTime = TimeCurrent() + PostWindowCooldownMin * 60;
               Print("Post-window cooldown started: ",
                     PostWindowCooldownMin, " minutes after cooldown filter end.");
            }
            else
            {
               //--- No post-window cooldown — go straight to active
               if(currentState == STATE_COOLDOWN) currentState = STATE_ACTIVE;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void CheckRecoveryMode()
{
   if(RecoveryEquityThreshold <= 0) return;
   double ep = (account.Equity() / account.Balance()) * 100;
   if(ep < RecoveryEquityThreshold && currentState == STATE_ACTIVE)
   {
      currentState = STATE_RECOVERY;
      Print("Entering Recovery Mode - Equity: ", DoubleToString(ep, 2), "%");
   }
   else if(ep >= RecoveryEquityThreshold && currentState == STATE_RECOVERY)
   {
      currentState = STATE_ACTIVE;
      Print("Exiting Recovery Mode - Equity: ", DoubleToString(ep, 2), "%");
   }
}

void CheckCooldown()
{
   if(currentState == STATE_COOLDOWN && TimeCurrent() >= cooldownEndTime)
   {
      currentState = STATE_ACTIVE;
      Print("Cooldown ended - Trading resumed");
   }
}

void EnterCooldown()
{
   if(CooldownMinutes <= 0) return;
   currentState    = STATE_COOLDOWN;
   cooldownEndTime = TimeCurrent() + (CooldownMinutes * 60);
   Print("Entering cooldown for ", CooldownMinutes, " minutes");
}

ENUM_ORDER_TYPE GetMADirection()
{
   if(CopyBuffer(maHandle, 0, 0, 1, maBuffer) != 1) return (ENUM_ORDER_TYPE)-1;
   return (m_symbol.Bid() > maBuffer[0]) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
}

ENUM_ORDER_TYPE GetTradeDirection()
{
   if(UseMASignal)
   {
      if(CountPositions(POSITION_TYPE_BUY)  > 0) return ORDER_TYPE_BUY;
      if(CountPositions(POSITION_TYPE_SELL) > 0) return ORDER_TYPE_SELL;
      return GetMADirection();
   }
   if(TradeDirection == TRADE_BUY_ONLY)  return ORDER_TYPE_BUY;
   if(TradeDirection == TRADE_SELL_ONLY) return ORDER_TYPE_SELL;
   return (ENUM_ORDER_TYPE)-1;
}

int CountPositions(ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)-1)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER)
            if(type == (ENUM_POSITION_TYPE)-1 || position.PositionType() == type)
               count++;
   return count;
}

double GetAnchorPrice(ENUM_POSITION_TYPE side)
{
   return (side == POSITION_TYPE_BUY) ? buyAnchor : sellAnchor;
}

//+------------------------------------------------------------------+
//| Open first position and set anchor                               |
//+------------------------------------------------------------------+
void OpenFirstPosition()
{
   ENUM_ORDER_TYPE dir = GetTradeDirection();
   if(dir == (ENUM_ORDER_TYPE)-1) return;

   if(dir == ORDER_TYPE_BUY  && lastBuyGridTime  == TimeCurrent()) return;
   if(dir == ORDER_TYPE_SELL && lastSellGridTime == TimeCurrent()) return;

   double price = (dir == ORDER_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();

   if(trade.PositionOpen(_Symbol, dir, LotSize, price, 0, 0, TRADE_COMMENT))
   {
      ENUM_POSITION_TYPE side = (dir == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      ResetSlots(side);
      if(side == POSITION_TYPE_BUY)  { buyAnchor  = price; lastBuyGridTime  = TimeCurrent(); }
      else                           { sellAnchor = price; lastSellGridTime = TimeCurrent(); }
      Print("First position opened: ", EnumToString(dir), " anchor=", price);
   }
}

//+------------------------------------------------------------------+
//| Core grid logic — slot-based, exact spacing, no duplicates       |
//+------------------------------------------------------------------+
bool ProcessGridSide(ENUM_POSITION_TYPE side)
{
   int sideCount = CountPositions(side);
   if(sideCount == 0)         return false;
   if(sideCount >= MaxOrders) return false;

   if(side == POSITION_TYPE_BUY  && lastBuyGridTime  == TimeCurrent()) return false;
   if(side == POSITION_TYPE_SELL && lastSellGridTime == TimeCurrent()) return false;

   double anchor = GetAnchorPrice(side);
   if(anchor == 0) return false;

   double gridStep     = GridStepPoints * m_symbol.Point();
   double currentPrice = (side == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();

   double rawDist = (side == POSITION_TYPE_BUY)
                    ? anchor - currentPrice
                    : currentPrice - anchor;

   if(rawDist < gridStep) return false;

   int maxSlot = (int)MathFloor(rawDist / gridStep);
   if(maxSlot < 1) return false;
   if(maxSlot >= MaxOrders) maxSlot = MaxOrders - 1;

   for(int slot = 1; slot <= maxSlot; slot++)
   {
      if(IsSlotFilled(side, slot)) continue;

      double placePrice = (side == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
      double newLot     = NormalizeDouble(LotSize + LotStep * slot, 2);
      ENUM_ORDER_TYPE order = (side == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      MarkSlot(side, slot);

      if(trade.PositionOpen(_Symbol, order, newLot, placePrice, 0, 0, TRADE_COMMENT))
      {
         if(side == POSITION_TYPE_BUY) lastBuyGridTime  = TimeCurrent();
         else                          lastSellGridTime = TimeCurrent();
         double slotPrice = (side == POSITION_TYPE_BUY)
                            ? anchor - slot * gridStep
                            : anchor + slot * gridStep;
         Print("Grid slot #", slot,
               " (", EnumToString(side), ")",
               " slotPrice=",  DoubleToString(slotPrice, m_symbol.Digits()),
               " placedAt=",   DoubleToString(placePrice, m_symbol.Digits()),
               " Lot=", DoubleToString(newLot, 2));
      }
      else
      {
         MarkSlot(side, slot);
         if(side == POSITION_TYPE_BUY) lastBuyGridTime  = TimeCurrent();
         else                          lastSellGridTime = TimeCurrent();
      }
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
void CheckGridEntry()
{
   if(CountPositions() >= MaxOrders) return;

   ENUM_POSITION_TYPE posType = POSITION_TYPE_BUY;
   bool found = false;
   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER)
         { posType = position.PositionType(); found = true; break; }

   if(!found) return;
   ProcessGridSide(posType);
}

//+------------------------------------------------------------------+
bool ManageBasket(ENUM_POSITION_TYPE side)
{
   if(CountPositions(side) == 0) return false;

   //--- TP by points OR by basket %
   if(CheckTakeProfitSide(side) || CheckBasketTPPercent(side))
   {
      ClosePositionsSide(side);
      ResetSlots(side);
      Print("Basket TP hit: ", EnumToString(side), " positions closed");
      return true;
   }

   ProcessGridSide(side);
   return false;
}

//+------------------------------------------------------------------+
void RunTrendRecoveryMode()
{
   if(!UseMASignal)
   {
      if(CheckTakeProfit() || CheckBasketTPPercentAll())
      {
         CloseAllPositions();
         ResetSlots(POSITION_TYPE_BUY);
         ResetSlots(POSITION_TYPE_SELL);
         if(CooldownMinutes > 0) EnterCooldown();
         return;
      }
      if(CountPositions() == 0) OpenFirstPosition();
      else CheckGridEntry();
      return;
   }

   ENUM_ORDER_TYPE maDir = GetMADirection();
   if(maDir == (ENUM_ORDER_TYPE)-1) return;

   ENUM_POSITION_TYPE newTrend = (maDir == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(!trInitialized) { trCurrentTrend = newTrend; trInitialized = true; }

   if(newTrend != trCurrentTrend)
   {
      Print("Trend flipped: ", EnumToString(trCurrentTrend), " -> ", EnumToString(newTrend));
      trCurrentTrend = newTrend;
   }

   ENUM_POSITION_TYPE oppSide = (trCurrentTrend == POSITION_TYPE_BUY)
                                ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   if(CountPositions(oppSide)        > 0) ManageBasket(oppSide);
   if(CountPositions(trCurrentTrend) == 0)
   {
      bool throttled = (trCurrentTrend == POSITION_TYPE_BUY)
                       ? (lastBuyGridTime  == TimeCurrent())
                       : (lastSellGridTime == TimeCurrent());
      if(throttled) return;

      double price = (trCurrentTrend == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
      ENUM_ORDER_TYPE ot = (trCurrentTrend == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(trade.PositionOpen(_Symbol, ot, LotSize, price, 0, 0, TRADE_COMMENT))
      {
         ResetSlots(trCurrentTrend);
         if(trCurrentTrend == POSITION_TYPE_BUY) { buyAnchor  = price; lastBuyGridTime  = TimeCurrent(); }
         else                                    { sellAnchor = price; lastSellGridTime = TimeCurrent(); }
         Print("Trend-Recovery: first ", EnumToString(ot), " opened at ", price);
      }
   }
   else ManageBasket(trCurrentTrend);
}

//+------------------------------------------------------------------+
bool CheckTakeProfitSide(ENUM_POSITION_TYPE side)
{
   double totalLots = 0, avgPrice = 0;
   int posCount = 0;

   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER
            && position.PositionType() == side)
         {
            totalLots += position.Volume();
            avgPrice  += position.PriceOpen() * position.Volume();
            posCount++;
         }

   if(posCount == 0) return false;
   avgPrice /= totalLots;

   double tpDist  = TakeProfitPoints * m_symbol.Point();
   double tpPrice = (side == POSITION_TYPE_BUY) ? avgPrice + tpDist : avgPrice - tpDist;
   double cur     = (side == POSITION_TYPE_BUY) ? m_symbol.Bid() : m_symbol.Ask();

   return ((side == POSITION_TYPE_BUY  && cur >= tpPrice) ||
           (side == POSITION_TYPE_SELL && cur <= tpPrice));
}

void ClosePositionsSide(ENUM_POSITION_TYPE side)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER
            && position.PositionType() == side)
            trade.PositionClose(position.Ticket());
}

bool CheckTakeProfit()
{
   double totalLots = 0, avgPrice = 0;
   int posCount = 0;
   ENUM_POSITION_TYPE posType = POSITION_TYPE_BUY;

   for(int i = 0; i < PositionsTotal(); i++)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER)
         {
            totalLots += position.Volume();
            avgPrice  += position.PriceOpen() * position.Volume();
            posType    = position.PositionType();
            posCount++;
         }

   if(posCount == 0) return false;
   avgPrice /= totalLots;

   double tpDist  = TakeProfitPoints * m_symbol.Point();
   double tpPrice = (posType == POSITION_TYPE_BUY) ? avgPrice + tpDist : avgPrice - tpDist;
   double cur     = (posType == POSITION_TYPE_BUY) ? m_symbol.Bid() : m_symbol.Ask();

   return ((posType == POSITION_TYPE_BUY  && cur >= tpPrice) ||
           (posType == POSITION_TYPE_SELL && cur <= tpPrice));
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(position.SelectByIndex(i))
         if(position.Symbol() == _Symbol && position.Magic() == MAGIC_NUMBER)
            trade.PositionClose(position.Ticket());
   Print("All positions closed - Take Profit reached");
}
//+------------------------------------------------------------------+
