/**
 * Generate Owner's C-Suite Playbook: 1000 questions + 1000 metrics
 */
const { Document, Packer, Paragraph, TextRun, Header, Footer, AlignmentType,
        LevelFormat, HeadingLevel, BorderStyle, PageNumber, PageBreak,
        Table, TableRow, TableCell, WidthType, ShadingType } = require('docx');
const fs = require('fs');

const NAVY = "1B3A4B";
const STEEL = "2E5A6B";
const ACCENT = "C45C26";
const LIGHT_GRAY = "F4F6F8";
const DARK = "1A1A1A";
const MUTED = "555555";

const border = { style: BorderStyle.SINGLE, size: 4, color: "CCCCCC" };
const borders = { top: border, bottom: border, left: border, right: border };

// ============================================================================
// QUESTION BANK — built by category, then padded/trimmed to exactly 1000
// ============================================================================

function Q(role, text) { return { role, text }; }

const questionBank = [];

// --- CEO / Strategy (1-80) ---
const ceoQs = [
  "What is our 12-month vision in one sentence—and can every VP recite it without looking at a slide?",
  "What is our 36-month vision, and which bets must pay off for it to be true?",
  "Are we growing profitably, or just growing revenue while margins erode?",
  "What is the single biggest existential risk to this company in the next 18 months?",
  "Which customers represent more than 10% of revenue, and what is our contingency if we lose one?",
  "Which customers represent more than 15% of revenue, and is the board comfortable with that concentration?",
  "What is our competitive moat—lanes, service, cost, people, or technology—and is it widening or narrowing?",
  "If we had to cut 10% of operating cost without losing revenue, where would we cut first?",
  "If we had to cut 20% of cost in a freight recession, what survives and what dies?",
  "Are we over-indexed on spot, contract, or dedicated—and is that mix intentional or accidental?",
  "What decisions have we delayed more than 90 days that still sit on the table?",
  "How many layers sit between a driver complaint and me, and is that acceptable?",
  "If I left for 90 days, what would break first—and who owns preventing that?",
  "What three leading indicators would tell me the business is turning south before the P&L does?",
  "Are we building a company that scales, or one held together by a few heroes?",
  "What would a sophisticated acquirer hate most about our business in due diligence?",
  "What would a sophisticated acquirer love most—and are we investing in that or starving it?",
  "Where are we deliberately saying no to freight, and who has authority to say no?",
  "What is our North American footprint strategy: densify existing lanes or expand geography?",
  "Are we an asset carrier, asset-light hybrid, or broker with trucks—and do our people act like it?",
  "What is the one capability we must be best-in-class at, or we do not deserve premium rates?",
  "How does our brand show up to drivers versus shippers—and are those stories consistent?",
  "What is our plan if diesel spikes 40% and spot rates fall simultaneously?",
  "Which competitors are winning our freight, and why—price, service, capacity, or relationships?",
  "What is our succession plan for every C-level seat, including mine?",
  "When did we last kill a pet project that was not working?",
  "What cultural behavior am I rewarding that I should stop rewarding?",
  "What cultural behavior am I punishing that I should start celebrating?",
  "How much of our strategy depends on hope versus contracted volume?",
  "What is our position on owner-operators versus company drivers over the next five years?",
  "Are terminal managers mini-CEOs with P&L ownership, or order-takers from corporate?",
  "What board-level risk register item is red right now, and what is the mitigation?",
  "How do we define 'winning' this year in numbers the shop floor would understand?",
  "What percent of executive time is spent on firefighting versus building systems?",
  "Which external forces—regulation, ELD, emissions, labor law—could rewrite our model?",
  "Are we investing enough in the next generation of leaders under 40?",
  "What is our M&A thesis: buy capacity, buy customers, buy lanes, or buy talent?",
  "If freight markets stay soft for two more years, what is Plan B for the balance sheet?",
  "Where have we over-promised customers and under-delivered operationally this year?",
  "What is the CEO's personal scorecard this quarter, published to the team?",
  "How transparent is our financial performance to managers who can actually affect it?",
  "What sacred cow in this company needs slaughtering this year?",
  "Are we optimizing for EBITDA, free cash flow, safety, or growth—and in what order when they conflict?",
  "What does 'customer intimacy' mean operationally for our top 20 accounts?",
  "How do we know when a lane or region should be exited?",
  "What is our public reputation in trucking forums and driver Facebook groups?",
  "When was the last unfiltered skip-level with drivers that changed a policy?",
  "What is our climate and emissions strategy—compliance theater or real fleet plan?",
  "How aligned are incentive plans across sales, ops, and safety so they do not fight each other?",
  "What would we do differently if we were starting this company from zero today?",
  "Which metrics on the company dashboard are vanity metrics we should delete?",
  "What is the opportunity cost of capital tied up in underused trailers and yard inventory?",
  "How prepared are we for a major cyber incident that takes down TMS for 72 hours?",
  "What is our relationship with our primary bank and insurance broker—strategic or transactional?",
  "Where are we under-insured or self-insured in a way that could threaten solvency?",
  "What is the quality of debate in the executive team—real challenge or polite agreement?",
  "Which VP is protecting a failing process because it is 'their' system?",
  "What is our plan for autonomous or advanced driver-assist technology over 10 years?",
  "How do we balance home-time promises with network design that actually needs drivers out longer?",
  "What percentage of my calendar last month was spent with customers, drivers, and shops versus internal meetings?",
  "If we doubled headcount in the office, would the fleet get better—or just busier?",
  "What is the one operational KPI I will not let slip even in a growth push?",
  "Are we a regional powerhouse pretending to be national, or national with weak regions?",
  "What partnerships (rail, final mile, 3PL, shipper private fleets) should we pursue or exit?",
  "How do we measure whether culture is improving or rotting?",
  "What is our policy on political and social issues that affect recruiting and customers?",
  "When rates recover, will we have the drivers and trucks to capture the upside?",
  "What legacy systems or people are we afraid to replace?",
  "How clear is decision rights: who decides rates, capacity, hires, CapEx over thresholds?",
  "What would make me proud of this company in 10 years beyond profit?",
  "Are we documenting institutional knowledge, or is it all in veterans' heads?",
  "What is our worst-case legal or compliance exposure that keeps counsel awake?",
  "How do we treat small customers versus large—and is that intentional brand positioning?",
  "What innovations from smaller carriers should we be embarrassed we have not adopted?",
  "Is our growth plan funded by operations cash, debt, or equity—and is the mix wise?",
  "What is the board asking that management still cannot answer with data?",
  "Where is politics beating performance in promotion decisions?",
  "What does our company owe the communities where terminals sit?",
  "If a major customer demanded carbon reporting tomorrow, could we produce it?",
  "What is the honest employee value proposition for non-driving staff?",
  "How will I know this year was a success beyond hitting budget?",
];
ceoQs.forEach(t => questionBank.push(Q("CEO / President", t)));

// --- CFO (expand heavily) ---
const cfoQs = [
  "What is our true cash runway if revenue dropped 25% for two quarters?",
  "What is our true cash runway if revenue dropped 40% for two quarters?",
  "How many days of DSO do we actually have by customer segment?",
  "Which customers pay late every month, and what is the cost of carrying them?",
  "What is our current debt service coverage ratio?",
  "When do credit facilities renew or reprice, and at what assumed rates?",
  "Are we profitable on an all-in cost per mile by fleet type?",
  "Are we profitable on an all-in cost per mile by terminal?",
  "What is our insurance renewal outlook for auto liability?",
  "Have we modeled a 20%, 30%, and 40% insurance premium increase?",
  "How much working capital is trapped in invoices over 45 days?",
  "How much working capital is trapped in invoices over 60 days?",
  "What is budget vs actual variance on fuel this month and YTD?",
  "What is budget vs actual variance on maintenance this month and YTD?",
  "What is budget vs actual variance on insurance this month and YTD?",
  "What is budget vs actual variance on driver pay this month and YTD?",
  "Are we capitalizing maintenance in a way that hides aging fleet costs?",
  "What is free cash flow after equipment payments, not just EBITDA?",
  "What is free cash flow after all lease and loan payments?",
  "Do we have covenant headroom, and what scenario breaches first?",
  "What percentage of revenue is locked in multi-month contracts?",
  "Where are we leaking money: empty miles, unbilled detention, waived accessorials, or rate undercuts?",
  "What is our tax exposure on equipment sales this year?",
  "What is the impact of bonus depreciation roll-off on cash taxes?",
  "Have we stress-tested the balance sheet for recession plus diesel spike?",
  "What is our operating ratio this month, trailing 3 months, and trailing 12?",
  "What is operating ratio by business unit (dry van, reefer, flatbed, dedicated, brokerage)?",
  "What is the true fully loaded cost of a seated tractor per day?",
  "What is the true fully loaded cost of an unseated tractor per day?",
  "How accurate is our weekly cash forecast versus actual for the last 12 weeks?",
  "What is our fuel surcharge recovery rate net of leakage and caps?",
  "Are factoring costs or early-pay discounts optimized?",
  "What is AR aging over 90 days, and is any of it pretend collectible?",
  "What is our bad debt reserve methodology, and is it honest?",
  "How much CapEx is maintenance-replacement versus growth?",
  "What is the ROI threshold for new tractor purchases, and do deals clear it?",
  "What is residual value risk if used truck prices drop 20%?",
  "Are trailer assets earning their keep, or is yard inventory bloated?",
  "What is our interest rate exposure on floating-rate debt?",
  "Do we have interest rate hedges, and are they effective?",
  "What is EBITDA to cash conversion quality (working capital swings)?",
  "Which P&L lines are consistently forecast wrong, and why?",
  "How many manual journal entries does month-end require, and what does that say about systems?",
  "Is revenue recognition clean for accessorials, fuel surcharge, and brokerage?",
  "What is the cost of empty repositioning as a percent of revenue?",
  "What is detention billed versus detention incurred?",
  "What is layover billed versus layover incurred?",
  "Are we double-counting savings initiatives that never hit the P&L?",
  "What is the fully loaded cost of the corporate overhead allocation to each terminal?",
  "Do terminal managers understand and trust their P&L?",
  "What is our audit letter management points, and are they closed?",
  "What internal controls over cash disbursements would fail a surprise test?",
  "How exposed are we to fuel card fraud and unauthorized spend?",
  "What is parts inventory value and obsolescence reserve?",
  "Are tire programs (new, retread, casing) costed correctly?",
  "What is workers' comp experience mod trend, and financial impact?",
  "What is cargo claims expense as percent of revenue by year?",
  "What is auto liability loss development—are reserves adequate?",
  "How do we allocate insurance cost to units and customers?",
  "Is owner-operator settlement accounting clean and dispute-free?",
  "What is the lag from delivery to invoice to cash for top customers?",
  "Are we leaving money on the table on contract rate escalators?",
  "What is the financial impact of service failures (penalties, lost freight, claims)?",
  "How much do we spend on outside counsel and settlements annually?",
  "What is our effective tax rate, and are we optimized legally across states?",
  "Do we have nexus and apportionment risk we have not modeled?",
  "What is the break-even loaded rate per mile by equipment type today?",
  "What is the break-even including target margin by equipment type?",
  "How sensitive is OR to a $0.05/mile rate change?",
  "How sensitive is OR to a 2% empty-mile change?",
  "How sensitive is OR to a 10% insurance change?",
  "What is the cash cost of driver turnover (recruiting, training, downtime)?",
  "Have we quantified the cost of unseated trucks last quarter?",
  "What CapEx can we defer 12 months without safety or compliance risk?",
  "What CapEx deferral would be reckless?",
  "Are lease vs buy decisions using real residual and maintenance assumptions?",
  "What is off-balance-sheet commitment exposure (leases, take-or-pay, guarantees)?",
  "How concentrated is banking relationship risk?",
  "Could we draw our full revolver today without issues?",
  "What is our minimum cash policy, and are we violating it in practice?",
  "Who has authority to grant customer credits, and is it controlled?",
  "What is the average credit memo rate, and why?",
  "Are intercompany or brokerage pass-throughs creating margin illusion?",
  "What is true brokerage net margin after claims and bad debt?",
  "How do we measure dedicated account profitability including standby time?",
  "Is the 13-week cash flow live and used for decisions, or a spreadsheet ritual?",
  "What KPIs does the audit committee actually want that we still lack?",
  "Where is fraud risk highest: AP, payroll, fuel, cargo, or customer collusion?",
  "When was the last surprise inventory count of high-value parts and tires?",
  "Are related-party transactions (if any) properly disclosed and priced?",
  "What is the financial impact of ELD/HOS constraints on utilization?",
  "How much premium do we pay for expedited maintenance and road calls?",
  "What is shop make-vs-buy economics for major component work?",
  "Are warranty recoveries maximized and booked timely?",
  "What percent of invoices require rework before customer acceptance?",
  "How fast can finance produce true lane P&L for a bid?",
  "Is there a single chart of accounts discipline across terminals?",
  "What shadow IT spreadsheets contain 'real' numbers finance does not control?",
  "How do we validate TMS revenue against billed revenue weekly?",
  "What is our policy for capitalizing software and implementation costs?",
  "Are we over-accruing or under-accruing bonuses and commissions?",
  "What is the quality of EBITDA add-backs we show lenders?",
  "If the bank asked for a quality-of-earnings review tomorrow, what would surface?",
  "What is our plan to improve OR by 200 basis points in 12 months—specific levers?",
  "Which costs are truly variable within 30 days versus sticky for a year?",
  "How much of 'fixed cost' is actually management choice dressed as fixed?",
  "What is the all-in cost of capital for this company today?",
  "Are equipment lenders still friendly, or is credit tightening on our name?",
  "What personal guarantees or cross-defaults should the owner worry about?",
  "How do dividend or distribution policies affect covenant and growth capacity?",
  "What is the economic profit (after cost of capital) of each major business line?",
];
cfoQs.forEach(t => questionBank.push(Q("CFO", t)));

// --- COO ---
const cooQs = [
  "What is loaded ratio and empty-mile percentage this month versus last year?",
  "What is empty-mile percentage by terminal and by fleet manager?",
  "Are we dispatching for utilization or just filling seats so trucks do not sit?",
  "How many trucks are deadlined right now, and why?",
  "What is average downtime days per mechanical event?",
  "What is on-time pickup percentage by customer tier?",
  "What is on-time delivery percentage by customer tier?",
  "Where are the chronic failure lanes—and why do we still run them?",
  "What is average tractor utilization (miles per truck per week) versus target?",
  "How often do drivers sit for freight versus freight sit for drivers?",
  "What is detention and layover exposure this month?",
  "Are we collecting detention and layover, or just tracking pain?",
  "Is trailer-to-tractor ratio right for the freight mix we haul?",
  "How many loads require last-minute brokerage, and at what cost?",
  "What is the root cause of the top 10 service failures last quarter?",
  "Is shop capacity matched to fleet age and duty cycle?",
  "What percentage of dispatches require human firefighting after first assignment?",
  "If major weather hits tomorrow, do we have a playbook or chaos?",
  "What is our network design philosophy: hub-and-spoke, regional, or irregular route?",
  "How many miles are wasted weekly on poor relay and handoff design?",
  "What is drop-and-hook percentage, and can we increase it with key shippers?",
  "How accurate are ETAs provided to customers versus actual?",
  "What is the average age of a load in the planning board before coverage?",
  "How many loads fall off or get rebrokered after commitment?",
  "What is driver dwell time at customer facilities for top 20 shippers?",
  "Which shippers are operationally toxic, and who is escalating that to sales?",
  "What is our weekend and holiday capacity plan quality?",
  "How do we handle appointment reschedules—proactive or reactive?",
  "What is relay failure rate and impact on service?",
  "Are fleet managers measured on service, utilization, and driver satisfaction together?",
  "What is the ratio of planners to trucks, and is it right?",
  "Where do we still use tribal knowledge instead of playbooks?",
  "What is yard inventory accuracy for trailers?",
  "How many trailers are lost, misassigned, or sitting dark?",
  "What is average trailer dwell in customer yards?",
  "Do we have trailer pool agreements that actually work?",
  "What is the process for weather holds and customer communication?",
  "How many hours of driver on-duty time is non-driving and unpaid friction?",
  "What is pre-trip failure rate and common defects?",
  "How often do we dispatch equipment that is near red-line on maintenance?",
  "What is the escalation path when a load will be late—documented and used?",
  "How integrated is brokerage cover with asset dispatch (one brain or two silos)?",
  "What percent of freight is planned more than 48 hours out versus same-day scramble?",
  "What is our policy on team drivers versus solo for long-haul lanes?",
  "Are we optimizing for miles, revenue, or driver home time when they conflict?",
  "How do we measure quality of load offers to drivers?",
  "What is load rejection rate by drivers, and top reasons?",
  "How many forced dispatches create retention risk?",
  "What is the standard for communication frequency to drivers on the road?",
  "Where do HOS constraints collide with customer appointments most often?",
  "What is our container/intermodal interface performance if applicable?",
  "How do we handle multi-stop and drop-lot complexity profitably?",
  "What is live load percentage versus drop, and the cost delta?",
  "Are customer routing guides followed, and what is compliance rate?",
  "What is the volume of after-hours exceptions and who covers them?",
  "How resilient is dispatch if our top three planners are out sick?",
  "What is the training program for new fleet managers?",
  "How long until a new fleet manager is competent and safe to run alone?",
  "What technology do planners ignore because it is useless or too slow?",
  "Where does the TMS lie about status, and how do we clean it?",
  "What is in-transit visibility accuracy for customers?",
  "How many check calls are still manual that should be automated?",
  "What is the process for OS&D (overage, shortage, damage) at delivery?",
  "How fast do we resolve OS&D to protect claims?",
  "What is our standard for sealing, load securement checks, and photos?",
  "Are reefer continuous vs cycle settings controlled and audited?",
  "What is temperature compliance rate for reefer loads?",
  "How many reefer claims last quarter, and root causes?",
  "For flatbed: what is securement incident rate and training currency?",
  "How do we manage tarping, permits, and pilot cars when needed?",
  "What is overweight/oversize compliance discipline?",
  "How do we plan around construction season and seasonal freight swings?",
  "What is peak season surge plan for capacity and temp labor?",
  "How many trucks are in the wrong region relative to freight demand this week?",
  "What is our empty reposition cost versus rejecting freight?",
  "When do we choose to sit a truck rather than take bad freight?",
  "Who has authority to take below-target rate freight, and with what guardrails?",
  "What is the average number of touches per load from booking to POD?",
  "Where is process waste in order-to-cash operations?",
  "How clean is POD capture rate and quality?",
  "What percent of invoices wait on missing POD or paperwork?",
  "How do we handle lumper fees—control, pass-through, leakage?",
  "What is the quality of customer routing and facility notes in the system?",
  "How often are facility notes wrong, causing driver failures?",
  "What is our standard for new customer onboarding operationally?",
  "Do we pilot new lanes before committing dedicated capacity?",
  "How do we measure terminal throughput and congestion?",
  "What is gate process efficiency at our yards?",
  "Are fuel island and DEF processes causing driver delays?",
  "How do we coordinate maintenance scheduling with load planning?",
  "What percent of PMs are done on time without stranding freight?",
  "What is road call frequency per million miles?",
  "How effective is breakdown recovery (time to rolling again)?",
  "What is our tire failure rate on the road versus in-shop catches?",
  "How do weather and mountain grades factor into planning time?",
  "What is team vs solo utilization and profitability comparison?",
  "Are we running equipment types mismatched to freight (costly over-spec or under-spec)?",
  "What is the plan for winterization and seasonal readiness?",
  "How do we audit dispatch decisions for favoritism or unfair load distribution?",
  "What would a lean process review of dispatch reveal as the biggest waste?",
  "If we stopped heroic heroics for 30 days, which processes would collapse?",
  "What operational KPI is green on the dashboard but red in customer experience?",
  "How do we close the loop from customer complaint to process change?",
  "What is the ops leadership bench strength two levels down?",
];
cooQs.forEach(t => questionBank.push(Q("COO", t)));

// --- CRO / Sales ---
const croQs = [
  "What is our bid win rate, and which customers habitually beat us down on rate?",
  "Are we pricing by all-in cost plus margin, or by market vibes?",
  "Which 20% of customers generate 80% of profit—not revenue?",
  "Which customers are in the bottom decile of profitability, and why keep them?",
  "What is the contract renewal pipeline for the next two quarters?",
  "At what rates and volumes are renewals expected?",
  "How much spot freight are we taking below all-in break-even?",
  "What is average revenue per loaded mile by equipment type?",
  "What is average revenue per total mile by equipment type?",
  "Are sales incentives aligned with margin and retention, or only booked revenue?",
  "Which customers generate chronic detention, claims, or unpaid accessorials?",
  "What is our share of wallet at top accounts?",
  "Who is stealing share at top accounts, and with what offer?",
  "How many new logos last quarter are still shipping with us?",
  "Is freight mix diversifying or concentrating risk?",
  "What is the true cost of a 'strategic' low-rate account including claims and driver misery?",
  "How many RFPs did we bid last quarter, and what was the hit rate by segment?",
  "Do we have a walk-away rate discipline that sales actually follows?",
  "Who can approve rates below floor, and how often do they?",
  "What is average length of sales cycle for new enterprise accounts?",
  "How healthy is the pipeline by stage and probability?",
  "What percent of revenue is from relationships that would die if one rep left?",
  "Are we multi-threaded in accounts, or single-threaded on one champion?",
  "What is customer NPS or satisfaction, and do we act on it?",
  "How often do sales commit capacity ops cannot deliver?",
  "What is the handoff quality from sales to ops on new awards?",
  "Do we have implementation playbooks for new dedicated business?",
  "What is churn reason analysis for lost accounts last year?",
  "Which industries or verticals should we specialize in?",
  "Which industries should we exit?",
  "How do we price volatility risk into spot and short-term contracts?",
  "What is our fuel surcharge schedule competitiveness and enforcement?",
  "Are accessorial schedules modern and enforced?",
  "How often do we leave money uncollected because sales waived fees?",
  "What is the win/loss analysis process quality?",
  "Do we know why we lose—price, service history, capacity, technology, or relationships?",
  "What is our value proposition beyond 'we have trucks'?",
  "How do we sell reliability and safety as paid value?",
  "What case studies and proof points do we actually use?",
  "Is marketing generating qualified leads, or is it logo merchandise?",
  "How aligned are pricing tools with real cost models from finance?",
  "How fast can we price a complex multi-lane bid accurately?",
  "What is contract language quality on detention, liability, and rate changes?",
  "Are evergreen contracts auto-renewing at stale rates?",
  "What is average age of rate agreements without market adjustment?",
  "How do we handle mini-bids and routing guide awards operationally?",
  "What percent of routing guide freight do we actually cover when awarded?",
  "Is primary vs backup award status tracked and managed?",
  "How do we recover volume when service fails?",
  "What is the escalation path for at-risk strategic accounts?",
  "Who owns customer success post-sale—sales or ops or a dedicated team?",
  "How often do executives visit top customer facilities?",
  "What is our strategy for Amazon, big retail, and high-compliance shippers?",
  "Can we meet shipper scorecard requirements (OTD, tender acceptance, visibility)?",
  "What is tender acceptance rate on primary lanes?",
  "What is tender rejection impact on future awards?",
  "How do we use data to propose network solutions, not just trucks?",
  "Are we leaving dedicated opportunities unexplored at existing accounts?",
  "What is cross-sell rate across modes/equipment types?",
  "How do we price and manage surge capacity for peak?",
  "What is our brokered freight strategy when assets are full—protect customer or protect margin?",
  "Do customers know when we broker, and is that transparent?",
  "What is the brand risk of double-brokering exposure in our network?",
  "How do we qualify credit for new customers before hauling?",
  "What freight have we hauled for non-paying customers in the last year?",
  "Is sales pressured to book bad credit freight to hit goals?",
  "How do regional sales and central pricing stay aligned?",
  "What is the compensation plan's unintended consequences?",
  "Are we paying commission on unprofitable freight?",
  "How do we claw back commission on bad debt or claims?",
  "What training do sales people get on operations reality?",
  "How many sales people have ridden with drivers or sat in dispatch?",
  "What is our competitive battlecard currency—updated or stale?",
  "How do we monitor competitor rate moves in key lanes?",
  "What is DAT/market rate vs our contract book gap by lane?",
  "When market is hot, do we reprice aggressively enough?",
  "When market is soft, do we defend floors or panic-cut?",
  "What is our strategy for shipper private fleets outsourcing?",
  "How prepared are we for nearshoring freight pattern shifts?",
  "What geographic expansion would actually be profitable?",
  "What geographic expansion would be ego-driven and dumb?",
  "How do we measure salesperson productivity beyond revenue?",
  "What is revenue and margin per sales FTE?",
  "How many accounts per rep is too many for real management?",
  "What is the ideal hunter vs farmer mix on the team?",
  "Are farmers actually growing accounts or just babysitting?",
  "What is our RFP go/no-go criteria checklist, and is it used?",
  "How often do we bid freight we should never win?",
  "What is the cost of bidding (people hours) versus expected value?",
  "Do we have a strategic account plan for each top 25 customer?",
  "What mutual action plans exist with key customers?",
  "How do we handle index-based pricing vs fixed rate?",
  "Are customers pushing for continuous bid e-auctions, and how do we respond?",
  "What is our stance on one-way rates and backhaul packages?",
  "How do we package round-trip economics honestly?",
  "What innovations (visibility, appointment AI, carbon reports) do customers demand that we lack?",
  "If we lost our top three customers, what is the 90-day survival plan?",
  "What customer should we fire this quarter, and who will do it?",
  "How will sales leadership personally take responsibility for margin, not just top line?",
];
croQs.forEach(t => questionBank.push(Q("CRO / Sales", t)));

// --- CHRO / People ---
const chroQs = [
  "What is true annualized driver turnover, and how does it compare to regional peers?",
  "What is fully loaded cost to replace one driver?",
  "Why do drivers leave in the first 90 days, and what have we fixed?",
  "Why do drivers leave after one year, and what have we fixed?",
  "Are we competitive on home time, pay transparency, equipment, and respect—not just CPM?",
  "What is the ratio of drivers per recruiter?",
  "What is the ratio of drivers per fleet manager?",
  "How many open seats right now versus qualified pipeline?",
  "What percentage of terminations are safety vs performance vs voluntary?",
  "Is dispatcher behavior a retention problem per exit interviews?",
  "Are we developing leaders from the driver bench or only hiring outside?",
  "What is non-driving staff turnover, and where is burnout?",
  "Do we have a real career path for drivers?",
  "How do drivers rate 'would recommend to a friend'?",
  "What is time-to-fill for a productive seated driver?",
  "What is offer acceptance rate, and why do candidates decline?",
  "Where do candidates drop out in the hiring funnel?",
  "Is our CDL recruiting dependent on schools, military, or poaching—and is that healthy?",
  "What is the quality of orientation: information dump or real onboarding?",
  "How long until a new driver feels competent and connected?",
  "What is trainer capacity, and are trainers rewarded properly?",
  "Are we pairing new drivers with the right mentors?",
  "What is student/trainee success rate to solo?",
  "How accurate is job advertising versus real routes and home time?",
  "Are we overselling in recruiting ads in a way that causes early quit?",
  "What is pay competitiveness by market and equipment type?",
  "How transparent is pay calculation—do drivers trust settlements?",
  "What is the volume of pay disputes weekly, and root causes?",
  "Are detention and accessorial pay to drivers fair and timely?",
  "How do benefits (health, 401k, PTO) compare to local employers competing for talent?",
  "What is healthcare cost trend and plan competitiveness?",
  "Are we using sign-on bonuses that create churn churn churn?",
  "What is retention after sign-on bonus cliffs?",
  "How do we handle tenure pay and performance pay?",
  "Is safety bonus design driving underreporting of incidents?",
  "What is employee relations case volume and themes?",
  "How many EEOC or labor complaints are open?",
  "What is our harassment and discrimination training effectiveness?",
  "How safe do women and minority drivers feel in our culture?",
  "What is the diversity of our driving and leadership workforce, and goals?",
  "Are bilingual resources available where the workforce needs them?",
  "What is absenteeism and no-call-no-show rate?",
  "How do we manage FMLA, ADA, and DOT medical certification complexity?",
  "What is DOT medical fail rate and support for getting drivers legal?",
  "How do we handle marijuana law changes vs DOT rules in messaging?",
  "What is the quality of performance management for fleet managers?",
  "Are toxic high-performing dispatchers tolerated?",
  "What is office staff engagement score?",
  "How often do we do stay interviews, not just exit interviews?",
  "What themes appear in stay interviews that leadership ignores?",
  "Is HR strategic or only transactional admin?",
  "How prepared are managers to have hard performance conversations?",
  "What is internal mobility rate?",
  "How many drivers have moved into shop, safety, or dispatch roles?",
  "What is our employer brand reputation on Glassdoor/Indeed/Trucking Truth?",
  "Who responds to public reviews, and with what tone?",
  "What is recruiting cost per seat by channel (referral, board, school, agency)?",
  "Which recruiting channels produce the longest-tenured drivers?",
  "Are employee referral programs funded and working?",
  "What is military and veteran hiring performance?",
  "How do we support drivers' families (communication, benefits, appreciation)?",
  "What is our policy on pet policies, rider policies, and team preferences?",
  "How do we handle home-time emergencies and bereavement humanely?",
  "What is unpaid time waiting that destroys morale?",
  "Are forced loops and forced dispatch policies written and fair?",
  "How do we measure fleet manager fairness in load assignment?",
  "What is the grievance or open-door process effectiveness?",
  "How many senior leaders came from operations versus pure corporate?",
  "What is leadership development spend per manager?",
  "Are we understaffed in HR business partners for a company our size?",
  "What is time-to-productivity for non-driving hires?",
  "How do we onboard remote or multi-terminal staff consistently?",
  "What is the quality of job descriptions versus actual work?",
  "Are we misclassifying roles or contractors in risky ways?",
  "What is wage-and-hour compliance confidence for non-exempt staff?",
  "How do we handle on-call planners and after-hours pay?",
  "What is burnout risk in safety, recruiting, and planning teams?",
  "Do we have a real mental health resource for drivers?",
  "How do we respond after critical incidents to support people?",
  "What is our drug testing vendor quality and MRO relationship?",
  "How fast is reasonable suspicion testing executed?",
  "What is the quality of background and PSP review standards?",
  "Are we too loose or too tight on hiring risk standards?",
  "What is recidivism of problem drivers we rehire?",
  "Should we have a no-rehire list that is actually enforced?",
  "How do seasonal capacity plans affect permanent culture?",
  "What is temp agency quality if we use temporary drivers or warehouse help?",
  "How do we celebrate tenure and safety milestones meaningfully?",
  "What recognition programs feel authentic versus cheesy?",
  "How often does the owner or CEO appear in driver communications?",
  "What is the state of uniform, PPE, and professional image standards?",
  "Are locker rooms, parking, and terminal facilities respectful of drivers?",
  "What facility investments would most improve driver dignity?",
  "How do we measure whether culture initiatives changed behavior?",
  "What HR metric is green while culture is red?",
  "If we froze hiring for 90 days, where would the business break first?",
  "What people risk would most damage us in a newspaper story?",
  "How succession-ready are key non-executive roles (lead planner, shop foreman, safety supervisor)?",
  "What is our 3-year workforce plan for driver availability trends?",
  "Are we preparing for autonomous-era workforce transition or ignoring it?",
  "What would make this company a destination employer for CDL talent in our region?",
];
chroQs.forEach(t => questionBank.push(Q("CHRO / People", t)));

// --- Safety ---
const safetyQs = [
  "Where do we stand on each CSA BASIC percentile?",
  "Which CSA BASIC is trending the wrong way, and why?",
  "What is preventable accident rate per million miles YoY?",
  "What is non-preventable accident rate, and are classifications honest?",
  "How many HOS violations still occur, and are they systemic?",
  "What is average claims severity for auto liability?",
  "What is claims frequency per million miles?",
  "Are high-risk drivers identified early, coached, and exited when needed?",
  "What is ELD compliance posture—tamper, edit abuse, missing data?",
  "Do drivers trust cameras or resent them, and how do we know?",
  "How many out-of-service events last quarter, and root causes?",
  "Is drug and alcohol program airtight including reasonable suspicion?",
  "What does the insurance carrier say about us in underwriting?",
  "Are we training for defensive driving or checking a box?",
  "What is lag between incident, investigation, and corrective action?",
  "If DOT walked in tomorrow, what three things make us lose sleep?",
  "What is our crash review board process quality?",
  "How consistent are preventability determinations?",
  "What is seat belt compliance observation rate?",
  "What is handheld phone / distraction event rate from cameras?",
  "How many coachable camera events are closed with real coaching?",
  "What is the ratio of safety managers to drivers?",
  "Are safety managers on the road observing, or only desk-bound?",
  "What is roadside inspection selection rate and clean inspection rate?",
  "How do we prepare drivers for Level 1 inspections?",
  "What is brake-related violation or defect rate?",
  "What is lighting and conspicuity defect rate?",
  "What is tire violation rate at roadside?",
  "How effective is pre-trip and post-trip inspection culture?",
  "Are DVIR defects closed before dispatch?",
  "What is cargo securement violation or incident rate?",
  "What is our hazardous materials compliance if we haul hazmat?",
  "Are shipping papers and placarding processes audited?",
  "What is speeding event rate from telematics (over threshold)?",
  "What is following-distance / harsh braking rate?",
  "How do we handle speed limiter policy and exceptions?",
  "What is nighttime accident rate versus daytime?",
  "What is accident rate for drivers under 1 year tenure?",
  "What is accident rate for drivers over age thresholds we track?",
  "How do weather-related crashes factor into dispatch decisions?",
  "What is our severe weather shutdown policy clarity?",
  "How many rollovers, jackknifes, or rear-ends last 24 months by type?",
  "What is litigation reserve adequacy for open injury cases?",
  "How often does safety learn from near misses?",
  "Is near-miss reporting rewarded or punished culturally?",
  "What is corrective action effectiveness verification rate?",
  "Are third-party administrators (TPA) for claims performing?",
  "What is average claim close time?",
  "How often do we settle claims we should defend, and why?",
  "What is subrogation recovery performance?",
  "Are dashcam and telematics data preserved for litigation holds?",
  "What is our FMCSA registration, authority, and insurance filing health?",
  "Any imminent conditional or unsatisfactory rating risk?",
  "How do we manage new entrant or branch authority if expanding?",
  "What is owner-operator safety onboarding and monitoring parity with company drivers?",
  "Are leased-on operators held to the same standards in practice?",
  "What is accident rate company vs contractor?",
  "How do we handle out-of-service drivers administratively?",
  "What is progressive discipline consistency for safety violations?",
  "Are we afraid to terminate unsafe high-producers?",
  "What is fatigue risk management beyond legal HOS?",
  "How do we detect log falsification patterns?",
  "What is personal conveyance and yard move abuse rate?",
  "How clean is our ELD unassigned driving event resolution?",
  "What is the safety onboarding curriculum length and retention testing?",
  "Do we use simulators or only road tests?",
  "What is road test failure rate and standards?",
  "How do we evaluate mountain, urban, and winter driving skills?",
  "What is incident rate at customer locations (dock, yard)?",
  "How do we manage visitor and yard pedestrian safety?",
  "What is shop safety incident rate and OSHA log quality?",
  "Are forklift and shop equipment certifications current?",
  "What is workers' comp frequency and severity trend?",
  "How do we handle return-to-work and light duty?",
  "What is ergonomic injury pattern (drivers and shop)?",
  "How prepared are we for a fatal accident response (notifications, family, media, counseling)?",
  "Is there a written crisis communication plan tested?",
  "What is relationship quality with state troopers and DOT officers in our footprint?",
  "Do we contest inspections and violations appropriately?",
  "What is DataQs success rate on incorrect violations?",
  "How do shipper scorecards treat our safety metrics?",
  "Are major shippers requiring specific camera or telematics standards we meet?",
  "What is our policy on passenger restrictions and unauthorized riders?",
  "How do we manage firearms and weapons policies legally and safely?",
  "What is theft and cargo crime incident rate on high-risk lanes?",
  "How do we route around high-crime corridors when needed?",
  "What is trailer seal protocol compliance?",
  "How do we handle high-value and theft-sensitive loads?",
  "What is our relationship with cargo crime task forces if relevant?",
  "Are safety KPIs in every operational leader's bonus plan?",
  "Does ops ever override safety holds, and under what governance?",
  "What safety technology ROI has been proven versus shelfware?",
  "What is the next safety technology investment case?",
  "How do we benchmark against peers beyond CSA?",
  "What would a world-class safety culture look like here in 3 years?",
  "Where is safety still seen as the 'department of no' rather than a business partner?",
  "What single safety metric should the owner see every Monday without fail?",
];
safetyQs.forEach(t => questionBank.push(Q("Safety / Compliance", t)));

// --- CTO / IT ---
const ctoQs = [
  "What is our single source of truth for load, cost, and margin—or do we have five?",
  "How many manual spreadsheet processes sit between dispatch and clean invoice?",
  "What is uptime for TMS, ELD, and payroll?",
  "What is the disaster recovery plan and last test date?",
  "Are we getting ROI from cameras, telematics, and optimization tools?",
  "How exposed are we to cyber risk on driver apps and portals?",
  "Can a manager pull true lane profitability in under five minutes?",
  "What tech debt blocks scale, and what is the retirement roadmap?",
  "Are vendors locked in with bad contracts?",
  "How much of digital transformation is theater versus cost-per-load reduction?",
  "Do drivers get tools that help them, or only apps that serve the back office?",
  "What is mean time to recover for critical systems?",
  "What is our RPO and RTO for TMS?",
  "Who has admin rights who should not?",
  "What is MFA coverage across critical systems?",
  "When was the last penetration test, and what remains open?",
  "How do we manage third-party vendor security risk?",
  "What is phishing simulation fail rate?",
  "How quickly do we revoke access when employees leave?",
  "Is there a privileged access management practice?",
  "What percent of integrations are real-time versus nightly batch?",
  "Where do status updates fail between ELD, TMS, and customer EDI?",
  "What is EDI error rate and manual intervention rate?",
  "How many customer portal logins are shared insecurely?",
  "What is data quality score for customer master, lane master, and asset master?",
  "Who owns data governance?",
  "How many duplicate customer or location records exist?",
  "What is the roadmap for modernizing TMS?",
  "Build vs buy vs modularize—what is the strategy?",
  "How dependent are we on one IT hero?",
  "What is IT ticket backlog age for ops-critical issues?",
  "How do we prioritize IT demand from sales, ops, finance, safety?",
  "What is mobile app crash rate for driver-facing tools?",
  "How is driver feedback on technology collected and acted on?",
  "Are we over-alerted with telematics noise causing alert fatigue?",
  "What AI or automation have we adopted carefully versus hype?",
  "Where could automation cut touches per load without hurting service?",
  "How do we handle ELD vendor lock-in and data export rights?",
  "Can we get our historical data out of vendors cleanly?",
  "What is cloud vs on-prem architecture risk?",
  "How are backups tested for restore, not just success logs?",
  "What is the business continuity plan if cell networks fail regionally?",
  "How do scanners, printers, and dock tech perform at terminals?",
  "What is Wi-Fi and connectivity quality for drivers at yards?",
  "Are fuel card and toll integrations reconciling cleanly?",
  "How automated is IFTA and IRP data collection?",
  "What is the quality of mileage engine accuracy?",
  "How do we prevent GPS spoofing or device tampering?",
  "What analytics tools exist, and who actually uses them weekly?",
  "Is there a self-serve BI layer for managers?",
  "How many 'official' dashboards conflict with each other?",
  "What is the process for changing a metric definition?",
  "How do we train users so software licenses are not wasted?",
  "What percent of software seats are unused?",
  "What is annual software spend as percent of revenue?",
  "Which systems should we sunset this year?",
  "How do we manage change management when rolling out new tools?",
  "What is user adoption rate 90 days after last major rollout?",
  "Are we collecting too much data we never use?",
  "What is privacy compliance posture for driver monitoring data?",
  "How do we handle driver requests related to camera footage?",
  "What is our policy on AI review of camera events?",
  "How integrated is maintenance software with dispatch?",
  "How integrated is accounting with TMS for automated invoicing?",
  "What is OCR/POD capture success rate?",
  "How much AP and expense processing is still manual?",
  "What is the roadmap for e-billing and customer invoice portals?",
  "How do we support customer API integrations for visibility?",
  "Are we a bottleneck for shippers' digital requirements?",
  "What is shadow IT risk (personal Google sheets, WhatsApp dispatch)?",
  "How do we secure messaging for operational communication?",
  "What is telecom spend optimization opportunity?",
  "How do we manage device lifecycle for tablets and phones?",
  "What is MDM (device management) coverage?",
  "How testable is our environment before production changes?",
  "What is change-failure rate for IT releases?",
  "Do we have staging environments that mirror production?",
  "How documented are critical business processes in systems?",
  "What happens when the TMS vendor has a multi-day outage?",
  "What is our SLA enforcement against key vendors?",
  "How often do we renegotiate tech contracts with leverage?",
  "What emerging tech (routing AI, dynamic pricing, predictive maintenance) has a real pilot?",
  "Which pilot should we kill as a science project?",
  "How do we measure technology ROI in dollars, not demos?",
  "Is IT a cost center only, or a margin lever with goals?",
  "What cybersecurity insurance do we carry, and does it match our controls?",
  "How would ransomware response work hour by hour?",
  "When was the last tabletop cyber exercise?",
  "What is the single biggest systems risk to payroll accuracy?",
  "What is the single biggest systems risk to customer billing accuracy?",
  "If we hired two more IT people, what would we stop outsourcing?",
  "If we had to cut IT spend 15%, what would we cut without bleeding?",
  "How aligned is the tech roadmap with the 3-year business strategy?",
  "What tech question can the C-suite not answer that they should be able to?",
];
ctoQs.forEach(t => questionBank.push(Q("CTO / CIO", t)));

// --- Maintenance / Fleet ---
const maintQs = [
  "What is average tractor age and replacement cycle?",
  "What is average trailer age and replacement cycle?",
  "What is maintenance CPM by unit age band?",
  "How many units are beyond economic repair but still running?",
  "What is parts inventory turns?",
  "Are warranty claims captured aggressively?",
  "What is shop backlog in days?",
  "How often do we farm out work, and at what premium?",
  "What is PM compliance rate—scheduled vs actual?",
  "What is residual value risk under soft used markets?",
  "What is road call rate per million miles?",
  "What is tow frequency and cost trend?",
  "What is engine derate or fault code recurrence rate?",
  "How effective is predictive maintenance versus reactive?",
  "What is tire CPM and failure modes?",
  "Are we running the right tire program for our duty cycle?",
  "What is brake life and cost by vocation?",
  "How clean is DPF/DEF related downtime?",
  "What is aftertreatment failure cost trend?",
  "Are techs certified and paid competitively vs dealers?",
  "What is tech turnover in the shops?",
  "How many open tech seats?",
  "Is shop tooling and diagnostic software current?",
  "What is comeback rate (rework) on repairs?",
  "How do we measure tech productivity fairly?",
  "What is bay utilization by shift?",
  "Do we need a second or third shift at key shops?",
  "How is mobile maintenance used for remote breakdowns?",
  "What OEM relationships give us parts priority?",
  "Are we standardized on a few powertrains or a parts zoo?",
  "What is the cost of fleet diversity (too many makes/models)?",
  "How do we decide spec for new builds (spec creep vs duty fit)?",
  "Are we over-spec'ing trucks sales loves but ops does not need?",
  "What is idle reduction technology effectiveness?",
  "How do APUs or alternative idle solutions perform financially?",
  "What is body and trailer damage rate from operations?",
  "How do we charge-back damage to drivers or customers fairly?",
  "What is door, floor, and roof trailer defect rate affecting claims?",
  "For reefer: unit age, failure rate, and pre-cool compliance?",
  "What is trailer tracking health and dark asset rate?",
  "How accurate is the asset register versus physical?",
  "When was the last full physical asset audit?",
  "What is sale-leaseback or financing impact on maintenance obligations?",
  "How do we manage campaign and recall completion?",
  "What is oil analysis program usage and findings acted on?",
  "Are we extending drains wisely or recklessly?",
  "What is fuel filter and contamination issue frequency?",
  "How do we handle winterization and A/C season surges?",
  "What is the capital plan for shop facilities and equipment?",
  "Are environmental shop compliance (oil, coolant, waste) tight?",
  "What is the make/buy decision framework for major component rebuilds?",
  "How do in-house rebuild quality and cost compare to exchange?",
  "What is glider or used truck strategy versus new?",
  "How do emissions regulations affect our replacement timing?",
  "What is the plan for CARB/Advanced Clean Truck or state rules if applicable?",
  "Are we tracking total cost of ownership by tractor ID end-to-end?",
  "Which 10% of units consume 40% of maintenance dollars?",
  "What is the process to park and sell problem units?",
  "How aligned are maintenance and finance on unit replacement ROI?",
  "What is trailer PM and inspection compliance (FHWA/annual)?",
  "How many trailers would fail a hard annual inspection today?",
  "What is landing gear, suspension, and abs trailer defect trend?",
  "How do we manage mobile repair vendors' quality and invoice accuracy?",
  "What percent of vendor invoices are audited?",
  "Is there warranty duplication or double billing leakage?",
  "How do parts obsolescence and dead stock get cleared?",
  "What is critical parts fill rate for A-items?",
  "How often does a truck sit waiting on parts more than 48 hours?",
  "What is the relationship with dealers for campaign support?",
  "How do driver write-ups get prioritized versus ignored?",
  "What is average time from DVIR defect to repair complete?",
  "Are safety defects gated from dispatch automatically?",
  "How do we prevent dispatch of unsafe equipment under load pressure?",
  "What metrics does the VP Maintenance review every morning?",
  "How cross-trained are shops across locations?",
  "What is the spare tractor strategy and cost of spares?",
  "How many pool trucks exist, and are they abused?",
  "What is washing and appearance standard impact on brand and corrosion?",
  "How do we manage corrosion in salt states?",
  "What is the fifth-wheel, gladhand, and connection failure rate?",
  "Are we capturing data for OEM defect patterns to pursue goodwill?",
  "What would a reliability-centered maintenance program change here?",
  "How far are we from world-class shop KPIs?",
  "What single maintenance metric should the owner see every Monday?",
];
maintQs.forEach(t => questionBank.push(Q("Maintenance / Fleet", t)));

// --- Legal / Risk / Governance ---
const legalQs = [
  "Are customer contracts current with clear liability, detention, and rate language?",
  "What is open litigation and claims reserve adequacy?",
  "Do owner-operator agreements protect us on insurance, cargo, and classification?",
  "Are we compliant on independent contractor classification in every state?",
  "What is cargo claims process SLA?",
  "How often do we pay claims we should defend?",
  "Have we reviewed broker authority, bonds, and double-broker risk?",
  "What is our MSAs status with top customers—signed and current?",
  "Where are we hauling on outdated rate confirmations only?",
  "What indemnity clauses have we accepted that are toxic?",
  "What is our limitation of liability strategy for cargo?",
  "Are released value and insurance requirements clear to customers?",
  "How do we manage certificates of insurance requests at scale?",
  "What is additional insured and waiver of subrogation exposure?",
  "Are lease agreements for real estate current and option-tracked?",
  "What environmental liabilities exist at older terminals?",
  "How clean is our corporate entity structure for liability isolation?",
  "Are subsidiaries and DBAs properly maintained?",
  "What is intellectual property protection for proprietary processes/software?",
  "How do we handle non-competes and non-solicits post-FTC/state changes?",
  "What employment handbooks are current by state?",
  "How many demand letters are open?",
  "What is average outside counsel spend per matter type?",
  "When do we use outside counsel versus inside?",
  "What is our document retention policy, and is it followed?",
  "Are litigation holds executed properly when needed?",
  "How do we manage subpoenas for ELD and camera data?",
  "What is privacy policy currency for websites and driver apps?",
  "Are we exposed on TCPA or marketing communication rules?",
  "What is M&A contract risk if we buy a fleet tomorrow?",
  "How do we diligence target carriers for chameleon carrier risk?",
  "What is our policy on subcontracting and cascading brokers?",
  "How do we verify authority and insurance of third-party carriers in real time?",
  "What is co-broker agreement quality?",
  "Are factors and payment terms creating UCC or priority issues?",
  "What personal guarantees has the owner signed that should be revisited?",
  "How current are board minutes and governance formalities?",
  "What related-party transactions need arm's length documentation?",
  "Are safety policies written, acknowledged, and enforceable?",
  "What is our social media and public statement policy for employees?",
  "How do we handle government investigations?",
  "What is FMCSA or state audit history and open conditions?",
  "Are IFTA, IRP, heavy highway tax, and 2290 processes audited internally?",
  "What is cabotage and cross-border compliance if applicable?",
  "How do we manage Canada/Mexico operational legal risk if we run them?",
  "What is trade compliance for cross-border freight?",
  "Are warehouse or cross-dock operations properly licensed and insured?",
  "What is liquor, tobacco, pharma, or high-risk commodity compliance if hauled?",
  "How do we manage food safety (FSMA) requirements for relevant freight?",
  "What is contract review SLA for sales so deals are not delayed or unsigned?",
  "Where has legal become a bottleneck versus a risk partner?",
  "What top three legal risks would you fund mitigation for if budget were unlimited?",
  "What legal risk are we accepting knowingly, and is the owner aware?",
];
legalQs.forEach(t => questionBank.push(Q("Legal / Risk", t)));

// --- Brokerage / Non-asset ---
const brokerQs = [
  "What is true net margin on brokerage after claims, bad debt, and rebates?",
  "How do we prevent double brokering in our carrier network?",
  "What is carrier onboarding quality and fraud detection rate?",
  "How many carrier fraud incidents last year, and loss amount?",
  "What is on-time performance for brokered freight vs asset?",
  "How do customers perceive our brokered coverage—transparent or bait-and-switch?",
  "What is carrier payment term policy, and does it hurt capacity access?",
  "How quickly do we pay good carriers versus industry norms?",
  "What is load-to-truck posting quality and fall-off rate?",
  "How dependent are we on a few carriers for cover?",
  "What is brokerage headcount productivity (margin per broker)?",
  "Are brokerage and asset teams collaborating or cannibalizing?",
  "What is the check call and tracking compliance on brokered loads?",
  "How do we handle stranded brokered loads at 2 a.m.?",
  "What is claims rate on brokered vs asset freight?",
  "Are customer contracts clear when we act as broker vs carrier?",
  "What is our bond and trust compliance status?",
  "How do we manage detention on brokered loads with carriers and customers?",
  "What technology differentiates our brokerage?",
  "If asset fleet disappeared, could brokerage stand alone profitably?",
  "What is sales compensation conflict between asset and broker modes?",
  "How do we price brokerage vs using our own trucks when both available?",
  "What is the ethical line on steering freight, and is it documented?",
  "How many carriers in the network are truly active last 90 days?",
  "What is carrier scorecard quality?",
  "How do we remove unsafe or unreliable carriers quickly?",
  "What is the process for high-value or temp-controlled brokered freight?",
  "Are we collecting correct paperwork (rate con, POD, NOA) every time?",
  "What is invoice dispute rate on brokerage?",
  "How exposed are we to broker shipper credit risk?",
  "What is average age of broker AR?",
  "How do we handle accessorial fights between shipper and carrier?",
  "What training do brokers get on fraud red flags?",
  "How do we verify pickup and delivery actually happened?",
  "What is our strategy versus mega-brokers on service and tech?",
  "Where should we specialize in brokerage verticals?",
  "What is the plan for digital freight matching experiments?",
  "How do we measure broker quality beyond margin (service, claims, compliance)?",
  "What is after-hours brokerage coverage model cost and effectiveness?",
  "Which brokerage lanes consistently lose money, and why still offered?",
];
brokerQs.forEach(t => questionBank.push(Q("Brokerage / Non-Asset", t)));

// --- Procurement / Fuel / Vendors ---
const procQs = [
  "What is fuel purchase optimization strategy (retail, bulk, networks, hedging)?",
  "How much fuel is bought off-network at bad prices?",
  "What is fuel card control and exception management quality?",
  "Are we hedging fuel, and does policy match risk appetite?",
  "What is DEF cost and supply reliability?",
  "How competitive are tire contracts and retread programs?",
  "What is OEM parts pricing versus aftermarket quality tradeoff?",
  "How often do we RFP major vendor categories?",
  "What is vendor concentration risk for critical parts?",
  "How do we manage shop supplies shrinkage?",
  "What is toll program optimization?",
  "Are we using the best toll and route tradeoffs for net cost?",
  "What is hotel and lodging policy cost for drivers when needed?",
  "How controlled is non-fuel over-the-road spend?",
  "What is towing and emergency road service contract performance?",
  "How do we audit large vendor invoices systematically?",
  "What savings initiatives were claimed but not realized in the P&L?",
  "What is the procurement policy threshold for competitive bids?",
  "Are conflicts of interest in vendor selection monitored?",
  "How do we onboard vendors for insurance and safety requirements?",
  "What is telecom and ELD device procurement lifecycle cost?",
  "How optimized is tire inventory across terminals?",
  "What is scrap tire and casing credit capture?",
  "Are bulk oil and fluid contracts best-in-class?",
  "How do we manage winter blend and seasonal fuel needs?",
  "What is the quality of national account pricing with truck stops?",
  "How much leakage exists in idle fuel burn we could avoid?",
  "What is the process for approving new vehicle specs with cost discipline?",
  "How do equipment upfit costs compare to budget?",
  "What facilities maintenance vendors perform, and which should be replaced?",
  "How do we track total cost of occupancy for terminals?",
  "What is janitorial, security, and snow removal cost discipline?",
  "Are we overpaying for software seats and overlapping tools?",
  "What is the preferred vendor list currency?",
  "How do we capture early-pay discounts without hurting cash?",
  "What procurement metric should finance and ops share weekly?",
  "Where is maverick spend highest?",
  "How empowered are terminal managers to buy locally versus forced national?",
  "What is the quality of PO compliance?",
  "How do we prevent duplicate payments and vendor fraud?",
];
procQs.forEach(t => questionBank.push(Q("Procurement / Fuel", t)));

// --- Customer Experience / Service ---
const cxQs = [
  "What is customer complaint volume trend and top themes?",
  "How fast do we acknowledge and resolve critical service failures?",
  "What is first-contact resolution rate for customer issues?",
  "Do customers have a single accountable owner?",
  "How often do we surprise customers positively versus only firefighting?",
  "What is proactive notification rate when delays occur?",
  "How accurate is tracking information customers see?",
  "What is appointment compliance communication quality?",
  "How do we close the loop after a claim with the customer relationship?",
  "What percent of QBRs with top customers include ops and safety, not only sales?",
  "What do customers say in lost-business interviews?",
  "How easy is it to do business with us administratively?",
  "What is invoice dispute rate and root cause?",
  "How customer-friendly is our detention documentation process?",
  "What is the experience of a driver at customer sites we still tolerate?",
  "Which customer sites should we put on a watch list for driver abuse?",
  "How do we escalate chronic shipper operational problems?",
  "What is our promise versus typical performance gap by account?",
  "How do we measure 'effort' customers expend to work with us?",
  "Are after-hours customer contacts handled professionally?",
  "What is the quality of our customer portal or EDI experience?",
  "How personalized is service for strategic accounts?",
  "What customer advisory input shapes our roadmap?",
  "When did we last lose a customer purely due to attitude or communication?",
  "How do we train CSRs and account reps on empathy plus honesty?",
  "What is the escalation matrix customers receive in writing?",
  "How do we handle peak season communication expectations?",
  "What is recovery playbook when we fail a critical load?",
  "Do we empower employees to fix small problems without six approvals?",
  "What CX metric is on the executive dashboard every month?",
];
cxQs.forEach(t => questionBank.push(Q("Customer Experience", t)));

// --- Terminal / Regional Leadership ---
const regionalQs = [
  "What is each terminal's operating ratio and trend?",
  "Which terminal is a chronic underperformer, and what is the fix-or-close plan?",
  "How comparable are KPI definitions across terminals?",
  "What is local market share and reputation by terminal?",
  "How strong is terminal manager bench strength?",
  "What local customer relationships exist only in one person's head?",
  "How do terminals share backhauls and capacity?",
  "What is inter-terminal political friction costing us?",
  "Are terminals measured on enterprise outcomes or local heroics?",
  "What is real estate utilization and excess yard space cost?",
  "Which terminals have safety cultures notably better or worse?",
  "How do local labor markets affect recruiting success by site?",
  "What facility investments have the highest ROI next year?",
  "How standardized are processes versus harmful local improvisation?",
  "Where is local improvisation actually smarter than corporate process?",
  "What is after-hours coverage model by terminal cost and quality?",
  "How do weather patterns uniquely affect each region?",
  "What is regional freight seasonality we under-plan for?",
  "How do state regulations differ in impact (chains, weight, emissions)?",
  "What is the communication cadence between corporate and terminals?",
  "Do terminal managers have real authority on staffing and freight selection?",
  "What decisions require corporate approval that should not?",
  "What decisions are local that should be standardized?",
  "How do we handle multi-terminal drivers and domicile fairness?",
  "What is home-time performance by domicile?",
  "Which domicile has the worst retention, and why?",
  "How do local shop capabilities differ, and does planning respect that?",
  "What is the quality of local community and DOT relationships?",
  "How prepared is each terminal for a major accident response?",
  "What regional competitor is winning, and what can we copy ethically?",
  "How do fuel prices and networks differ by region in net CPM?",
  "What is empty mile rate by region relative to freight balance?",
  "Where should we densify terminals versus open new ones?",
  "What is the business case standard for a new terminal?",
  "Which terminal would we not reopen if it burned down tomorrow?",
  "How do we transfer best practices from the best terminal to the rest?",
  "What is the leadership development path for terminal managers to VP?",
  "How often does senior leadership visit each terminal unannounced?",
  "What do drivers say differs unfairly by terminal?",
  "What single regional metric tells you the network is out of balance?",
];
regionalQs.forEach(t => questionBank.push(Q("Terminal / Regional", t)));

// --- Dedicated / Private fleet solutions ---
const dedicatedQs = [
  "What is true dedicated account profitability including standby and empty?",
  "How many dedicated accounts are under water but 'strategic'?",
  "What is the renewal risk on each dedicated contract in 12 months?",
  "Are dedicated assets stranded when volume dips?",
  "How flexible are contracts on volume bands and rate resets?",
  "What is driver preference for dedicated vs irregular route, and retention impact?",
  "How do we price weekend and holiday dedicated coverage?",
  "What is equipment utilization on dedicated versus network?",
  "How often do dedicated customers scope-creep without rate changes?",
  "What governance exists for out-of-scope requests?",
  "How do we handle customer-caused delays on dedicated?",
  "What is the exit clause quality if a dedicated account turns toxic?",
  "Are KPIs in dedicated contracts aligned with how we operate?",
  "What penalties exist, and how often do we pay them?",
  "How do we staff dedicated management (on-site vs remote)?",
  "What is on-site behavior and professionalism standard?",
  "How integrated are we with customer warehouse systems?",
  "What continuous improvement savings have we delivered and shared?",
  "Do customers see us as a commodity carrier or a operations partner?",
  "What dedicated bid would we refuse even if high revenue?",
  "How do we transition drivers when a dedicated account ends?",
  "What is the stranded cost risk of custom-spec equipment?",
  "How do multi-year dedicated deals protect against cost inflation?",
  "What index or reopeners exist for labor, insurance, and equipment?",
  "How transparent are we with customers on cost drivers?",
  "What is implementation timeline accuracy for new dedicated starts?",
  "Where have startups failed, and lessons learned?",
  "How do we measure customer executive satisfaction on dedicated?",
  "What is the upsell path from dedicated to broader network freight?",
  "If a top dedicated account put the business out to bid, would we win—and at what margin?",
];
dedicatedQs.forEach(t => questionBank.push(Q("Dedicated Solutions", t)));

// --- Owner-operator / Contractor ---
const ooQs = [
  "What percent of capacity is owner-operator versus company?",
  "Is that mix strategic or historical accident?",
  "What is OO turnover versus company driver turnover?",
  "How competitive is our contractor settlement package?",
  "Are fuel surcharges and accessorials passed fairly to OOs?",
  "What is average OO weekly net, and do they believe they can earn it?",
  "How many OO trucks are parked for lack of freight fairness?",
  "What is the quality of freight distribution between company and OO?",
  "Are we treating OOs as partners or disposable capacity?",
  "What insurance requirements do we impose, and are they market-standard?",
  "How do we monitor OO safety without misclassifying employment?",
  "What legal review frequency exists for contractor model risk?",
  "How do lease-purchase programs perform for the contractor and for us?",
  "Is our lease-purchase program a path to ownership or a trap?",
  "What is default rate on lease-purchase?",
  "How transparent are chargebacks and escrow practices?",
  "What is escrow balance policy fairness?",
  "How do we handle OO truck breakdowns and freight commitments?",
  "What technology do OOs must use, and who pays?",
  "How do we onboard OO equipment for safety and branding?",
  "What is brand risk when OO appearance or behavior is poor?",
  "How do we exit bad OO relationships quickly?",
  "What is cargo claim responsibility clarity with OOs?",
  "How do detention payments flow to OOs?",
  "Are we compliant with Truth-in-Leasing (if applicable) fully?",
  "What is the voice-of-contractor feedback process?",
  "How often do OO councils or forums influence decisions?",
  "What would a class-action classification claim look like against us?",
  "How state-by-state is our contractor risk map?",
  "Should we increase or decrease OO mix over 3 years, and why?",
];
ooQs.forEach(t => questionBank.push(Q("Owner-Operator / Contractor", t)));

// --- Sustainability / ESG / Future ---
const esgQs = [
  "What is our emissions baseline, and can we report it?",
  "Which customers require carbon data we cannot yet provide?",
  "What is idle reduction progress in measurable gallons?",
  "How does aerodynamic and tire tech figure into fuel strategy?",
  "What is our stance on renewable diesel or alternative fuels?",
  "Are electric or hybrid pilots realistic for our duty cycles?",
  "What infrastructure would depot charging require, and who pays?",
  "How do we evaluate OEM zero-emission truck claims versus real TCO?",
  "What grants or incentives exist we are not using?",
  "How do emissions rules in CA and other states affect fleet deployment?",
  "What is trailer gap reduction and skirt compliance ROI?",
  "How do we train drivers on fuel-efficient driving with incentives?",
  "What is our environmental spill and waste compliance record?",
  "How do investors or lenders score our ESG readiness?",
  "Is ESG a sales advantage or only a cost center for us?",
  "What community engagement is real versus PR?",
  "How do we manage noise and neighbor issues at terminals?",
  "What is the long-term residual risk of diesel-only fleets?",
  "How do we avoid stranded asset risk on new powertrains?",
  "What 10-year fleet energy strategy would you defend to the board?",
];
esgQs.forEach(t => questionBank.push(Q("Sustainability / Future", t)));

// --- M&A / Growth / Corporate development ---
const maQs = [
  "What is our inorganic growth thesis in one paragraph?",
  "What targets fit culture and network—not just EBITDA logos?",
  "How do we value a fleet differently from a brokerage?",
  "What integration failures have we seen in the industry that we would avoid?",
  "How would we integrate safety cultures post-close?",
  "How would we integrate driver pay systems without a revolt?",
  "What is our capacity to fund an acquisition without covenant stress?",
  "What earnout structures protect us from seller optimism?",
  "How do we diligence CSA, claims tail, and insurance history?",
  "How do we diligence customer concentration at a target?",
  "What chameleon carrier or authority history red flags do we screen?",
  "How do we retain key dispatchers and sales post-acquisition?",
  "What is Day 1 / Day 100 integration playbook maturity?",
  "Should we sell terminals, equipment, or non-core lanes?",
  "What carve-outs or spin scenarios make sense?",
  "How do private equity expectations differ from family ownership if relevant?",
  "What is our valuation in a soft freight market versus peak?",
  "Are we building to sell, building to last, or unclear?",
  "What minority investments or joint ventures make sense (shop, tech, last mile)?",
  "How do we avoid acquisition indigestion that destroys core service?",
  "What is the opportunity cost of management distraction during a deal?",
  "Who leads diligence, and do they have trucking scar tissue?",
  "What is our walk-away criteria in a competitive process?",
  "How do we handle competing with a target for drivers post-announcement?",
  "What brand architecture do we use after buying a regional name?",
  "How soon must systems consolidate, and at what risk?",
  "What working capital true-ups bite buyers in trucking deals?",
  "How do equipment appraisals and soft residual markets affect price?",
  "What insurance novation and loss history transfer issues do we plan for?",
  "If we never acquire, how do we still hit our 5-year ambition?",
];
maQs.forEach(t => questionBank.push(Q("M&A / Corporate Development", t)));

// Expand with dimension-based unique questions to reach 1000
function expandToThousand(bank) {
  // Extra specialty roles (generated) so the book covers the full trucking org chart
  const extraRoles = [
    "Pricing / Yield Management", "Claims / Insurance Ops", "Driver Experience",
    "Network Design", "Quality / Continuous Improvement", "Treasury / Credit",
    "Training / Academy", "Facilities / Real Estate", "Communications / Brand"
  ];

  const themes = [
    "What is our current performance on %s, and is the trend improving or worsening?",
    "Who owns %s end-to-end, and are they resourced to win?",
    "What would world-class look like for %s in 12 months?",
    "What is the leading indicator for %s that we underweight today?",
    "Where does %s break down at 2 a.m. on a Sunday?",
    "What customer pain is created when %s fails?",
    "What driver pain is created when %s fails?",
    "How do we know %s is measured honestly rather than gamed?",
    "What cross-functional conflict blocks progress on %s?",
    "What decision about %s have we deferred that is now expensive?",
    "If we invested 10% more in %s, what ROI would we expect?",
    "If we had to cut 10% from spending on %s, what goes first without killing the business?",
    "What external benchmark do we use for %s, and how do we compare?",
    "What skill gaps on the team limit %s?",
    "What system or data gap limits %s?",
    "How does incentive design help or hurt %s?",
    "What would a new hire in 90 days say is broken about %s?",
    "How do we escalate when %s is red for more than 30 days?",
    "What story do we tell the board about %s versus the unvarnished truth?",
    "What is the single process change that would most improve %s this quarter?",
    "Looking at the last 90 days, what specifically improved or worsened regarding %s?",
    "What early warning signs of trouble in %s are we currently ignoring?",
    "What report would you put on my desk every Monday about %s?",
    "Compared to our best competitor, where do we stand on %s?",
    "What is the cost of inaction on %s over the next year?",
  ];

  const topicsByRole = {
    "Pricing / Yield Management": [
      "lane-level floor rates", "spot vs contract arbitrage", "seasonal pricing agility", "accessorial yield",
      "discount approval discipline", "competitor rate intelligence", "contribution margin by lane",
      "capacity-aware pricing", "fuel surcharge design", "deal desk effectiveness"
    ],
    "Claims / Insurance Ops": [
      "claim intake speed", "reserve accuracy", "subrogation capture", "litigation strategy",
      "driver statement quality", "evidence preservation", "customer claim communication",
      "repeat claim locations", "cargo packaging failures", "total cost of risk reporting"
    ],
    "Driver Experience": [
      "home-time promise keeping", "pay stub clarity", "dispatch respect", "equipment pride",
      "terminal amenities", "communication responsiveness", "unfair load assignment perception",
      "recognition authenticity", "app usability", "family support"
    ],
    "Network Design": [
      "lane density", "relay design quality", "domicile balance", "seasonal rebalance",
      "freight selection filters", "empty reposition rules", "customer mix by corridor",
      "mode shift opportunities", "drop lot strategy", "capacity pooling"
    ],
    "Quality / Continuous Improvement": [
      "root cause discipline", "kaizen cadence", "standard work audits", "defect definition clarity",
      "cross-functional CI projects", "benefit tracking to P&L", "idea pipeline from drivers",
      "process documentation", "handoff quality", "recurring failure elimination"
    ],
    "Treasury / Credit": [
      "customer credit limits", "collection effectiveness", "bank covenant forecasting", "payment term strategy",
      "fraudulent load risk", "factoring decisions", "cash concentration", "surety and bond capacity",
      "counterparty risk limits", "early-pay discount economics"
    ],
    "Training / Academy": [
      "new driver curriculum effectiveness", "trainer capacity", "skills verification", "remedial training triggers",
      "manager coaching skills", "safety refresher quality", "customer-specific training",
      "technology training adoption", "knowledge retention testing", "training ROI"
    ],
    "Facilities / Real Estate": [
      "yard capacity planning", "lease vs own strategy", "facility condition index", "security of premises",
      "driver facility quality", "environmental compliance at sites", "expansion optionality",
      "sublease of excess space", "capex for safety at terminals", "location strategy vs freight"
    ],
    "Communications / Brand": [
      "driver communication clarity", "crisis communications readiness", "employer brand consistency",
      "customer brand promise alignment", "social reputation management", "internal comms cadence",
      "executive visibility", "message discipline in downturns", "community relations", "recruiting creative honesty"
    ],
  };

  // Dedupe seeds, group by role (preserve order within role)
  const byRole = new Map();
  const existing = new Set();
  for (const q of bank) {
    if (existing.has(q.text)) continue;
    existing.add(q.text);
    if (!byRole.has(q.role)) byRole.set(q.role, []);
    byRole.get(q.role).push(q);
  }

  // Build specialty extras grouped by role for even allocation later
  const specialtyByRole = new Map(extraRoles.map(r => [r, []]));
  for (const role of extraRoles) {
    const topics = topicsByRole[role];
    for (const topic of topics) {
      for (const tmpl of themes) {
        const text = tmpl.replace(/%s/g, topic);
        if (!existing.has(text)) {
          existing.add(text);
          specialtyByRole.get(role).push(Q(role, text));
        }
      }
    }
  }

  // Deepen core seats with follow-ups
  const coreTopics = {
    "CEO / President": ["operating cadence", "P&L ownership culture", "risk appetite", "board reporting honesty"],
    "CFO": ["true cost to serve", "cash conversion", "insurance renewal readiness", "capital rationing"],
    "COO": ["service recovery speed", "planner decision quality", "network rebalance", "exception backlog"],
    "CRO / Sales": ["margin leakage in deals", "renewal risk", "toxic freight", "capacity promises"],
    "CHRO / People": ["manager-caused turnover", "recruiting truth in advertising", "dispatcher behavior", "career paths"],
    "Safety / Compliance": ["high-risk driver latency", "coaching quality", "CSA trajectory", "claims severity drivers"],
    "CTO / CIO": ["single source of truth", "touchless load percentage", "cyber readiness", "dead software spend"],
    "Maintenance / Fleet": ["worst 10% units", "PM honesty", "parts wait time", "shop capacity"],
  };
  const deepenThemes = [
    "How would you prove progress on %s with one chart?",
    "What is the unofficial workaround people use because %s is broken?",
    "Who gets hurt first when %s fails—drivers, customers, or cash?",
    "What is your 30-60-90 day plan if %s is still red next quarter?",
    "What budget ask related to %s have you been afraid to make?",
  ];
  for (const [role, topics] of Object.entries(coreTopics)) {
    if (!byRole.has(role)) byRole.set(role, []);
    for (const topic of topics) {
      for (const tmpl of deepenThemes) {
        const text = tmpl.replace(/%s/g, topic);
        if (!existing.has(text)) {
          existing.add(text);
          byRole.get(role).push(Q(role, text));
        }
      }
    }
  }

  // Target mix: keep strong coverage of seed roles, reserve ~180 for specialty chapters
  const SPECIALTY_TARGET = 180;
  const SEED_TARGET = 1000 - SPECIALTY_TARGET;

  // Proportional trim of seed roles down to SEED_TARGET while keeping every role
  const seedRoles = [...byRole.keys()];
  const counts = Object.fromEntries(seedRoles.map(r => [r, byRole.get(r).length]));
  let total = seedRoles.reduce((s, r) => s + counts[r], 0);
  // Never drop a role below min(its size, 20) when possible
  const MIN_KEEP = 20;
  while (total > SEED_TARGET) {
    // Trim from largest role that is still above MIN_KEEP
    let victim = null;
    let victimSize = -1;
    for (const r of seedRoles) {
      if (counts[r] > MIN_KEEP && counts[r] > victimSize) {
        victim = r;
        victimSize = counts[r];
      }
    }
    if (!victim) {
      // all at floor — trim largest absolute
      for (const r of seedRoles) {
        if (counts[r] > 1 && counts[r] > victimSize) {
          victim = r;
          victimSize = counts[r];
        }
      }
    }
    if (!victim) break;
    counts[victim]--;
    total--;
  }

  const out = [];
  for (const r of seedRoles) {
    out.push(...byRole.get(r).slice(0, counts[r]));
  }

  // Even specialty allocation across extra roles
  const perSpecialty = Math.floor(SPECIALTY_TARGET / extraRoles.length);
  let specialtyAdded = 0;
  for (const role of extraRoles) {
    const take = Math.min(perSpecialty, specialtyByRole.get(role).length);
    out.push(...specialtyByRole.get(role).slice(0, take));
    specialtyAdded += take;
  }
  // Remainder of specialty budget: round-robin leftovers
  let need = 1000 - out.length;
  let guard = 0;
  while (need > 0 && guard < 10000) {
    guard++;
    let progressed = false;
    for (const role of extraRoles) {
      if (need <= 0) break;
      const arr = specialtyByRole.get(role);
      const already = out.filter(q => q.role === role).length;
      // already includes only specialty if role wasn't a seed role
      const used = Math.min(already, arr.length);
      // find next unused specialty question for role
      const next = arr.find(q => !out.includes(q));
      if (next) {
        out.push(next);
        need--;
        progressed = true;
      }
    }
    if (!progressed) break;
  }

  // Final pad from unused seed tails
  if (out.length < 1000) {
    const seen = new Set(out.map(q => q.text));
    for (const r of seedRoles) {
      for (const q of byRole.get(r)) {
        if (out.length >= 1000) break;
        if (!seen.has(q.text)) {
          seen.add(q.text);
          out.push(q);
        }
      }
    }
  }

  if (out.length !== 1000) {
    console.warn("Question count after balance:", out.length);
  }
  return out.slice(0, 1000);
}

// ============================================================================
// METRIC BANK — 1000 metrics
// ============================================================================

function M(category, name, definition, owner) {
  return { category, name, definition, owner };
}

const metricSeed = [];

// Financial (expand)
const finMetrics = [
  ["Operating Ratio", "Operating expenses ÷ operating revenue × 100", "CFO"],
  ["Operating Ratio (ex-fuel)", "OR with fuel expense and surcharge removed for underlying view", "CFO"],
  ["EBITDA", "Earnings before interest, tax, depreciation, amortization", "CFO"],
  ["EBITDA Margin", "EBITDA ÷ revenue", "CFO"],
  ["EBITDAR", "EBITDA plus rent/lease for comparison across financing structures", "CFO"],
  ["Adjusted EBITDA", "EBITDA with agreed add-backs; track add-back quality", "CFO"],
  ["Free Cash Flow", "Operating cash flow − CapEx", "CFO"],
  ["Free Cash Flow after Debt Service", "FCF − principal & interest", "CFO"],
  ["Cash Balance", "Available cash and equivalents", "CFO"],
  ["Liquidity (cash + undrawn revolver)", "Total immediate liquidity", "CFO"],
  ["Revenue", "Total operating revenue", "CFO"],
  ["Revenue Growth YoY %", "Year-over-year revenue change", "CFO"],
  ["Freight Revenue", "Linehaul + accessorials related to hauling", "CFO"],
  ["Fuel Surcharge Revenue", "FSC billed", "CFO"],
  ["Accessorial Revenue", "Detention, layover, stop-off, etc.", "CFO"],
  ["Brokerage Revenue", "Non-asset revenue", "CFO"],
  ["Brokerage Gross Margin $", "Brokerage revenue − purchased transportation", "CFO"],
  ["Brokerage Gross Margin %", "Brokerage GM ÷ brokerage revenue", "CFO"],
  ["Revenue per Total Mile", "Total freight revenue ÷ all miles", "CFO"],
  ["Revenue per Loaded Mile", "Freight revenue ÷ loaded miles", "CRO"],
  ["Revenue per Tractor per Week", "Freight revenue ÷ average seated tractors ÷ weeks", "CFO"],
  ["Revenue per Driver per Week", "Freight revenue ÷ average working drivers ÷ weeks", "CFO"],
  ["Cost per Total Mile (all-in)", "All operating costs ÷ total miles", "CFO"],
  ["Variable Cost per Mile", "Fuel, driver pay, tolls, variable maint, etc. ÷ miles", "CFO"],
  ["Fixed Cost per Mile", "Fixed costs ÷ miles", "CFO"],
  ["Driver Pay CPM", "Driver compensation ÷ miles", "CFO"],
  ["Fuel CPM (gross)", "Fuel spend ÷ miles", "CFO"],
  ["Fuel CPM (net of FSC)", "Fuel spend − FSC revenue ÷ miles", "CFO"],
  ["Maintenance CPM", "Maintenance & tires ÷ miles", "Maint"],
  ["Insurance CPM", "Premiums + retained losses ÷ miles", "CFO"],
  ["Tire CPM", "Tire cost ÷ miles", "Maint"],
  ["Toll CPM", "Tolls ÷ miles", "CFO"],
  ["Purchase Transportation CPM", "Purchased capacity cost ÷ related miles/loads", "CFO"],
  ["Contribution Margin per Load", "Revenue − variable cost per load", "CFO"],
  ["Contribution Margin per Mile", "CM ÷ miles", "CFO"],
  ["Gross Margin %", "Gross profit ÷ revenue", "CFO"],
  ["SG&A as % of Revenue", "Overhead efficiency", "CFO"],
  ["Corporate Overhead per Tractor", "Allocated overhead ÷ tractors", "CFO"],
  ["Days Sales Outstanding", "AR collection cycle", "CFO"],
  ["DSO by Customer Tier", "DSO segmented", "CFO"],
  ["AR > 45 Days $", "Aging risk", "CFO"],
  ["AR > 60 Days $", "Aging risk", "CFO"],
  ["AR > 90 Days $", "Aging risk", "CFO"],
  ["Bad Debt % of Revenue", "Write-offs ÷ revenue", "CFO"],
  ["Days Payable Outstanding", "AP cycle", "CFO"],
  ["Cash Conversion Cycle", "DSO + inventory days − DPO", "CFO"],
  ["Working Capital", "Current assets − current liabilities", "CFO"],
  ["Working Capital / Revenue", "WC intensity", "CFO"],
  ["Debt Service Coverage Ratio", "Cash for debt ÷ debt service", "CFO"],
  ["Interest Coverage Ratio", "EBIT ÷ interest", "CFO"],
  ["Net Debt", "Interest-bearing debt − cash", "CFO"],
  ["Net Debt / EBITDA", "Leverage", "CFO"],
  ["Debt / Equity", "Capital structure", "CFO"],
  ["Current Ratio", "Current assets ÷ current liabilities", "CFO"],
  ["Quick Ratio", "Liquid assets ÷ current liabilities", "CFO"],
  ["CapEx $", "Capital expenditures", "CFO"],
  ["CapEx % of Revenue", "CapEx intensity", "CFO"],
  ["Maintenance CapEx vs Growth CapEx", "Split of capital spend", "CFO"],
  ["Equipment Debt Balance", "Loans/leases on rolling stock", "CFO"],
  ["Average Interest Rate on Equipment Debt", "Financing cost", "CFO"],
  ["Lease Expense", "Operating lease cost", "CFO"],
  ["Return on Assets", "NOI or NI ÷ assets", "CFO"],
  ["Return on Invested Capital", "NOPAT ÷ invested capital", "CFO"],
  ["Return on Equity", "NI ÷ equity", "CFO"],
  ["Budget vs Actual Revenue Variance %", "Forecast accuracy", "CFO"],
  ["Budget vs Actual OR Variance (bps)", "Cost control vs plan", "CFO"],
  ["Forecast Accuracy (cash) MAPE", "Cash forecast error", "CFO"],
  ["Forecast Accuracy (revenue) MAPE", "Revenue forecast error", "CFO"],
  ["Fuel Surcharge Recovery Rate", "FSC billed ÷ target fuel cost recovery", "CFO"],
  ["Accessorial Capture Rate", "Billed & collected ÷ earned accessorials", "CFO"],
  ["Detention Capture Rate", "Detention collected ÷ detention incurred", "CFO"],
  ["Credit Memo Rate", "Credits ÷ billed revenue", "CFO"],
  ["Invoice Accuracy Rate", "Clean invoices ÷ total", "CFO"],
  ["Invoice Cycle Time (days)", "Delivery to invoice", "CFO"],
  ["Billing Lag (days)", "Average delay to bill", "CFO"],
  ["Unbilled Revenue $", "Work done not invoiced", "CFO"],
  ["Accrual Quality Index", "Late adjustments magnitude", "CFO"],
  ["Audit Adjustments $", "External audit corrections", "CFO"],
  ["Internal Control Exceptions #", "Control failures found", "CFO"],
  ["Payroll Accuracy Rate", "Error-free pays", "CFO"],
  ["Settlement Dispute Rate", "Driver pay disputes ÷ settlements", "CFO"],
  ["Cost of Driver Turnover $", "Fully loaded replacement cost total", "CFO"],
  ["Unseated Tractor Cost $", "Idle seated capacity loss", "CFO"],
  ["Insurance Premium $", "Total premium", "CFO"],
  ["Insurance Deductible / SIR Spend $", "Retained loss payments", "CFO"],
  ["Total Cost of Risk", "Premiums + retained + admin + indirect", "CFO"],
  ["Workers Comp Mod Factor", "Experience modification", "Safety"],
  ["Effective Tax Rate", "Tax ÷ pretax income", "CFO"],
  ["Sales Tax / Use Tax Exposure Items #", "Open exposure count", "CFO"],
  ["IFTA Fuel Tax Cost $", "Net fuel tax", "CFO"],
  ["Heavy Highway Use Tax $", "Form 2290 cost", "CFO"],
  ["Bank Covenant Headroom %", "Distance to breach", "CFO"],
  ["Revolver Utilization %", "Drawn ÷ commitment", "CFO"],
  ["Customer Concentration Top 1 %", "Largest customer revenue share", "CFO"],
  ["Customer Concentration Top 5 %", "Top 5 revenue share", "CFO"],
  ["Customer Concentration Top 10 %", "Top 10 revenue share", "CFO"],
  ["Profit Concentration Top 10 Customers %", "Profit share top 10", "CFO"],
  ["Lane Profitability Positive %", "Share of lanes with positive CM", "CFO"],
  ["% Revenue Below Variable Cost", "Value-destructive revenue share", "CFO"],
  ["% Revenue Below Fully Allocated Cost", "Below full-cost revenue share", "CFO"],
  ["EBITDA per Tractor", "EBITDA ÷ average tractors", "CFO"],
  ["Cash Yield per Tractor", "FCF ÷ average tractors", "CFO"],
];
finMetrics.forEach(([n, d, o]) => metricSeed.push(M("Financial Health", n, d, o)));

const opsMetrics = [
  ["Empty Mile %", "Empty miles ÷ total miles", "COO"],
  ["Loaded Ratio", "Loaded miles ÷ total miles", "COO"],
  ["Deadhead Miles per Dispatch", "Empty to pickup average", "COO"],
  ["Miles per Tractor per Week", "Utilization", "COO"],
  ["Miles per Driver per Week", "Driver utilization", "COO"],
  ["Loaded Miles per Tractor per Week", "Productive utilization", "COO"],
  ["Loads per Tractor per Week", "Load throughput", "COO"],
  ["Average Length of Haul", "Miles per load", "COO"],
  ["On-Time Pickup %", "OTP", "COO"],
  ["On-Time Delivery %", "OTD", "COO"],
  ["On-Time Service % (combined)", "Pickup and delivery composite", "COO"],
  ["Customer Appointment Compliance %", "Met appointments", "COO"],
  ["First-Assignment Success Rate", "Completed without reassignment", "COO"],
  ["Load Reassignment Rate", "Reassigns ÷ loads", "COO"],
  ["Tender Acceptance Rate", "Accepted tenders ÷ received", "CRO"],
  ["Tender Rejection Rate", "Rejected ÷ received", "CRO"],
  ["Fall-off Rate", "Fallen loads after commit ÷ commits", "COO"],
  ["Broker Cover Rate (asset shortfall)", "Brokered covers when asset needed", "COO"],
  ["Drop-and-Hook %", "D&H loads ÷ total", "COO"],
  ["Live Load %", "Live loads ÷ total", "COO"],
  ["Multi-stop Load %", "Multi-stop share", "COO"],
  ["Average Stops per Load", "Stop density", "COO"],
  ["Detention Hours per Load", "Average detention", "COO"],
  ["Detention Incidence %", "Loads with detention ÷ loads", "COO"],
  ["Layover Incidence %", "Loads with layover", "COO"],
  ["Driver Dwell Hours at Shipper", "Average dwell", "COO"],
  ["Driver Dwell Hours at Consignee", "Average dwell", "COO"],
  ["Trailer-to-Tractor Ratio", "Trailers ÷ tractors", "COO"],
  ["Trailer Utilization %", "Working trailer time/miles proxy", "COO"],
  ["Trailer Dwell Days (customer)", "Average days at customer", "COO"],
  ["Trailer Dwell Days (yard)", "Average days in yard", "COO"],
  ["Dark Trailer Count", "Unlocated trailers", "COO"],
  ["Yard Inventory Accuracy %", "System vs physical", "COO"],
  ["Tractor Seated %", "Seated tractors ÷ total active", "CHRO"],
  ["Unseated Tractors #", "Open power units", "CHRO"],
  ["Deadlined Tractors %", "OOS maintenance ÷ fleet", "Maint"],
  ["Available Tractor %", "Ready line ÷ fleet", "COO"],
  ["Dispatch Productivity (loads/planner/day)", "Planner throughput", "COO"],
  ["Touches per Load", "Human touches order-to-POD", "COO"],
  ["Manual Check Call %", "Manual tracking events", "COO"],
  ["Automated Tracking %", "Auto status updates", "IT"],
  ["ETA Accuracy (within window %)", "Predicted vs actual", "COO"],
  ["In-Transit Visibility Accuracy %", "Correct status share", "COO"],
  ["Exception Rate per 100 Loads", "Ops exceptions", "COO"],
  ["Service Failure Rate", "Failures ÷ loads", "COO"],
  ["Critical Service Failures #", "High-severity failures", "COO"],
  ["Weather Delay Rate", "Weather-delayed loads share", "COO"],
  ["Relay Success Rate", "Successful relays ÷ planned", "COO"],
  ["Average Transit Time vs Standard", "Plan variance", "COO"],
  ["HOS Impacted Delay Rate", "Delays primarily HOS", "COO"],
  ["Driver Sitting for Freight Hours", "Idle productive time", "COO"],
  ["Freight Sitting for Driver Hours", "Uncovered demand time", "COO"],
  ["Same-Day Cover %", "Covered same day as tender", "COO"],
  ["Advance Plan % (>48h)", "Planned early share", "COO"],
  ["Route Guide Compliance %", "Per customer routing", "COO"],
  ["Fuel MPG (fleet)", "Miles per gallon", "COO"],
  ["Idle Time %", "Idle hours ÷ engine hours", "COO"],
  ["Idle Gallons", "Estimated gallons idled", "COO"],
  ["Speed Over Threshold Event Rate", "Speeding events / 1k miles", "Safety"],
  ["Harsh Braking Events / 1k Miles", "Telematics", "Safety"],
  ["Harsh Acceleration Events / 1k Miles", "Telematics", "Safety"],
  ["Cornering Events / 1k Miles", "Telematics", "Safety"],
  ["Road Calls per Million Miles", "Breakdown frequency", "Maint"],
  ["Average Time to Roadside Recovery (hrs)", "Breakdown response", "Maint"],
  ["PM Compliance %", "On-time PMs", "Maint"],
  ["DVIR Open Defect Age (days)", "Defect closure lag", "Maint"],
  ["Safety Gate Dispatch Blocks #", "Unsafe equipment blocked", "Safety"],
  ["POD Capture Rate within 24h", "POD timeliness", "COO"],
  ["POD Quality Pass Rate", "Usable POD share", "COO"],
  ["OS&D Rate", "OS&D incidents ÷ loads", "COO"],
  ["Temperature Compliance % (reefer)", "In-range deliveries", "COO"],
  ["Reefer Claim Rate", "Temp claims ÷ reefer loads", "COO"],
  ["Securement Incident Rate", "Flatbed securement issues", "Safety"],
  ["Overweight Citation Rate", "Weight violations", "Safety"],
  ["Lumper Fee Leakage $", "Unrecovered lumper", "CFO"],
  ["Planner Overtime Hours", "Labor pressure signal", "COO"],
  ["After-Hours Exception Volume", "Nights/weekend exceptions", "COO"],
  ["Network Imbalance Index", "Regional truck vs freight mismatch", "COO"],
  ["Empty Reposition Cost $", "Cost of empties planned", "COO"],
  ["Average Loaded Rate Acceptance Latency", "Time to accept/reject load", "COO"],
  ["Customer Facility Score (ops friction)", "Composite dwell/fail score", "COO"],
  ["Loads per Day", "Volume throughput", "COO"],
  ["Miles per Day (fleet)", "Fleet activity", "COO"],
  ["Weekend Load Share %", "Weekend volume", "COO"],
  ["Team Load Share %", "Team driver volume", "COO"],
  ["Average Driver On-Duty Non-Driving Hours", "Friction time", "COO"],
  ["Appointment Reschedule Rate", "Reschedules ÷ appointments", "COO"],
  ["Missed Pickup Rate", "Missed PUs ÷ planned", "COO"],
  ["Missed Delivery Rate", "Missed Dels ÷ planned", "COO"],
  ["Recovered Service Failures %", "Failures recovered same cycle", "COO"],
  ["Standard Work Audit Pass %", "Process adherence", "COO"],
];
opsMetrics.forEach(([n, d, o]) => metricSeed.push(M("Operations & Network", n, d, o)));

const revMetrics = [
  ["Contract Revenue Mix %", "Contract ÷ total revenue", "CRO"],
  ["Spot Revenue Mix %", "Spot ÷ total", "CRO"],
  ["Dedicated Revenue Mix %", "Dedicated ÷ total", "CRO"],
  ["Brokerage Mix % of Revenue", "Brokerage share", "CRO"],
  ["Avg Contract Rate / Loaded Mile", "Contract yield", "CRO"],
  ["Avg Spot Rate / Loaded Mile", "Spot yield", "CRO"],
  ["Spot vs Contract Rate Spread", "Spot premium/discount", "CRO"],
  ["Bid Win Rate %", "Wins ÷ bids", "CRO"],
  ["Bid Volume #", "Bids submitted", "CRO"],
  ["RFP Hit Rate by Vertical %", "Win rate segmented", "CRO"],
  ["New Logo Count", "New customers won", "CRO"],
  ["New Logo Revenue $", "Revenue from new logos", "CRO"],
  ["New Logo Revenue %", "New logo share of revenue", "CRO"],
  ["Customer Churn Rate (accounts)", "Accounts lost", "CRO"],
  ["Customer Churn Rate (revenue)", "Revenue lost to churn", "CRO"],
  ["Volume Retention %", "Retained volume YoY", "CRO"],
  ["Gross Revenue Retention %", "Without expansion", "CRO"],
  ["Net Revenue Retention %", "With expansion", "CRO"],
  ["Share of Wallet (strategic accounts)", "Our spend share", "CRO"],
  ["Wallet Expansion $", "Incremental wallet captured", "CRO"],
  ["Avg Revenue per Customer", "Revenue / active customers", "CRO"],
  ["Avg Margin per Customer", "Profit / customers", "CRO"],
  ["Top Decile Customer Profit %", "Profit from best customers", "CRO"],
  ["Bottom Decile Customer Profit $", "Loss from worst customers", "CRO"],
  ["Unprofitable Customer Count", "Customers with negative CM", "CRO"],
  ["Strategic Account Plan Coverage %", "Top accounts with live plans", "CRO"],
  ["QBR Completion Rate (top accounts)", "QBRs held", "CRO"],
  ["Pipeline Coverage Ratio", "Pipeline ÷ target", "CRO"],
  ["Pipeline Weighted Value $", "Probability-weighted pipeline", "CRO"],
  ["Average Sales Cycle Days", "Lead to award", "CRO"],
  ["Quote-to-Award Conversion %", "Awards ÷ quotes", "CRO"],
  ["Rate Renewal Uplift %", "Avg renewal change", "CRO"],
  ["Stale Rate Agreement %", "Agreements >X months unreviewed", "CRO"],
  ["Below-Floor Approval Rate", "Exceptions ÷ quotes", "CRO"],
  ["Below-Floor Revenue %", "Revenue under floor", "CRO"],
  ["Accessorial Schedule Enforcement %", "Fees charged per policy", "CRO"],
  ["Fuel Surcharge Schedule Compliance %", "Correct FSC applied", "CRO"],
  ["Tender Award Primary %", "Primary awards share", "CRO"],
  ["Routing Guide Compliance (our cover)", "Cover when awarded", "CRO"],
  ["Lost Business $ (known)", "Documented losses", "CRO"],
  ["Win/Loss Review Completion %", "Reviews done", "CRO"],
  ["Sales Capacity Commit Error Rate", "Oversells causing failure", "CRO"],
  ["Implementation On-Time Start %", "New business starts on time", "CRO"],
  ["Customer NPS", "Net promoter score", "CX"],
  ["Customer CSAT", "Satisfaction score", "CX"],
  ["Complaint Rate per 100 Loads", "Complaints density", "CX"],
  ["Critical Complaint Close Time (hrs)", "Severe issue cycle", "CX"],
  ["Proactive Delay Notification %", "Notified before customer asks", "CX"],
  ["Invoice Dispute Rate", "Disputed invoices share", "CFO"],
  ["Credit Risk Overrides #", "Hauls against credit policy", "CFO"],
  ["Average Length of Customer Relationship (years)", "Tenure", "CRO"],
  ["Multi-product Customer %", "Customers using >1 service", "CRO"],
  ["Lane Density (loads/lane/week)", "Density on key lanes", "CRO"],
  ["Market Rate Index vs Book", "Market vs our rates", "CRO"],
  ["Yield Management Action Rate", "Reprices executed", "CRO"],
  ["Revenue per Sales FTE", "Sales productivity", "CRO"],
  ["Margin per Sales FTE", "Sales profit productivity", "CRO"],
  ["Accounts per Rep", "Workload", "CRO"],
  ["Commission on Unprofitable Freight %", "Misaligned pay signal", "CRO"],
  ["Customer Concentration Risk Score", "Composite risk", "CRO"],
];
revMetrics.forEach(([n, d, o]) => metricSeed.push(M("Revenue & Customers", n, d, o)));

const peopleMetrics = [
  ["Driver Headcount (active)", "Working drivers", "CHRO"],
  ["Driver Turnover Annualized %", "Separations annualized", "CHRO"],
  ["Company Driver Turnover %", "Company only", "CHRO"],
  ["Owner-Operator Turnover %", "OO only", "CHRO"],
  ["First-90-Day Turnover %", "Early attrition", "CHRO"],
  ["First-180-Day Turnover %", "Mid-early attrition", "CHRO"],
  ["Voluntary Turnover %", "Quits", "CHRO"],
  ["Involuntary Turnover %", "Terminations", "CHRO"],
  ["Safety-Related Termination %", "Of involuntary", "CHRO"],
  ["Average Driver Tenure (months)", "Experience base", "CHRO"],
  ["Median Driver Tenure (months)", "Tenure distribution", "CHRO"],
  ["Cost per Hire (driver)", "Recruiting cost / hire", "CHRO"],
  ["Fully Loaded Replacement Cost per Driver", "All-in replacement", "CHRO"],
  ["Time to Fill (days)", "Open to productive", "CHRO"],
  ["Time to Productivity (days)", "Hire to solo standard", "CHRO"],
  ["Offer Acceptance Rate %", "Accepted ÷ offers", "CHRO"],
  ["Application-to-Hire Conversion %", "Funnel efficiency", "CHRO"],
  ["Recruiting Pipeline (qualified candidates)", "Active qualified", "CHRO"],
  ["Open Driver Seats #", "Vacancies", "CHRO"],
  ["Seat Fill Rate %", "Filled ÷ target seats", "CHRO"],
  ["Referral Hire %", "Referrals ÷ hires", "CHRO"],
  ["Referral Hire 12-Month Retention %", "Quality of referrals", "CHRO"],
  ["Recruiting Channel ROI by Source", "Tenure/cost by source", "CHRO"],
  ["CDL School Hire Performance Index", "School hire success", "CHRO"],
  ["Military Hire %", "Veteran share of hires", "CHRO"],
  ["Drivers per Recruiter", "Recruiter load", "CHRO"],
  ["Drivers per Fleet Manager", "Span of control", "CHRO"],
  ["Fleet Manager Turnover %", "FM attrition", "CHRO"],
  ["Dispatcher / Planner Turnover %", "Ops office attrition", "CHRO"],
  ["Non-Driver Turnover %", "Staff attrition", "CHRO"],
  ["Employee NPS / eNPS", "Recommend employer", "CHRO"],
  ["Driver NPS", "Driver-specific eNPS", "CHRO"],
  ["Engagement Survey Score", "Engagement index", "CHRO"],
  ["Stay Interview Completion Rate", "Stay interviews done", "CHRO"],
  ["Exit Interview Completion Rate", "Exits covered", "CHRO"],
  ["Top Exit Reason Category Share", "Primary leave reasons", "CHRO"],
  ["Home-Time Promise Kept %", "Actual vs sold home time", "CHRO"],
  ["Average Days Out per Tour", "Tour length", "COO"],
  ["Home Time Days per Month (avg)", "Home time delivered", "CHRO"],
  ["Forced Dispatch Rate", "Forced ÷ dispatches", "COO"],
  ["Load Offer Acceptance Rate (drivers)", "Accepted offers", "COO"],
  ["Pay Dispute Rate", "Disputes ÷ settlements", "CHRO"],
  ["Settlement Accuracy %", "Correct first-time pay", "CHRO"],
  ["Average Driver Weekly Gross Pay", "Earnings level", "CHRO"],
  ["Average Driver Weekly Net Pay", "Take-home proxy", "CHRO"],
  ["Pay Competitiveness Index vs Market", "Market compa-ratio", "CHRO"],
  ["Benefits Enrollment %", "Participation", "CHRO"],
  ["Health Plan Cost per Employee", "Benefits cost", "CHRO"],
  ["Sign-on Bonus Clawback / Churn Rate", "Bonus-related churn", "CHRO"],
  ["Training Hours per Driver / Year", "Training investment", "Safety"],
  ["Trainer-to-Trainee Ratio", "Training capacity", "CHRO"],
  ["Student Success-to-Solo Rate %", "Training completion", "CHRO"],
  ["Internal Promotion Rate %", "Promotions ÷ employees", "CHRO"],
  ["Drivers Moved to Non-Driving Roles #", "Career pathing", "CHRO"],
  ["Absenteeism Rate %", "Unplanned absence", "CHRO"],
  ["No-Call No-Show Rate", "NCNS incidents", "CHRO"],
  ["Overtime Hours (non-driver)", "Staff OT", "CHRO"],
  ["HR Case Volume", "ER cases", "CHRO"],
  ["Time to Resolve ER Case (days)", "ER cycle time", "CHRO"],
  ["Diversity Hiring Rate (defined groups)", "Inclusive hiring", "CHRO"],
  ["Leadership Diversity %", "Leadership composition", "CHRO"],
  ["Manager Quality Score", "Upward feedback", "CHRO"],
  ["Performance Review Completion %", "Reviews done", "CHRO"],
  ["Regrettable Attrition %", "Loss of high performers", "CHRO"],
  ["Offer Decline Reason: Pay %", "Declines for pay", "CHRO"],
  ["Offer Decline Reason: Home Time %", "Declines for home time", "CHRO"],
  ["Glassdoor / Public Rating", "External reputation", "CHRO"],
  ["Recruiting Cost per Seated Truck", "Cost to seat", "CHRO"],
  ["Orientation Satisfaction Score", "New hire feedback", "CHRO"],
  ["30-Day New Hire Pulse Score", "Early experience", "CHRO"],
  ["DOT Medical Certification Lapse #", "Medical compliance", "Safety"],
  ["License / Medical Expiration Compliance %", "Credential currency", "Safety"],
];
peopleMetrics.forEach(([n, d, o]) => metricSeed.push(M("People & Drivers", n, d, o)));

const safetyMetrics = [
  ["Preventable Accidents per Million Miles", "Core safety outcome", "Safety"],
  ["Total Accidents per Million Miles", "All accidents frequency", "Safety"],
  ["Preventable Accident Count", "Count", "Safety"],
  ["Injury Accidents per Million Miles", "Injury frequency", "Safety"],
  ["Fatalities", "Count (target zero)", "Safety"],
  ["TRIR", "Total recordable incident rate", "Safety"],
  ["DART Rate", "Days away/restricted/transfer", "Safety"],
  ["Lost Time Injury Rate", "LTI frequency", "Safety"],
  ["CSA Unsafe Driving Percentile", "BASIC", "Safety"],
  ["CSA Crash Indicator Percentile", "BASIC", "Safety"],
  ["CSA HOS Compliance Percentile", "BASIC", "Safety"],
  ["CSA Vehicle Maintenance Percentile", "BASIC", "Safety"],
  ["CSA Controlled Substances Percentile", "BASIC", "Safety"],
  ["CSA Driver Fitness Percentile", "BASIC", "Safety"],
  ["CSA HM Percentile (if applicable)", "BASIC", "Safety"],
  ["Out-of-Service Rate % (driver)", "Driver OOS / inspections", "Safety"],
  ["Out-of-Service Rate % (vehicle)", "Vehicle OOS / inspections", "Safety"],
  ["Roadside Inspection Count", "Inspection volume", "Safety"],
  ["Clean Inspection %", "No violation inspections", "Safety"],
  ["HOS Violations per Million Miles", "HOS frequency", "Safety"],
  ["ELD Malfunction / Data Diagnostic Rate", "Device health", "Safety"],
  ["Unassigned Driving Events Aging >72h #", "ELD hygiene", "Safety"],
  ["Personal Conveyance Misuse Events #", "PC abuse", "Safety"],
  ["Speeding Violations / Citations #", "Citations", "Safety"],
  ["Seat Belt Non-Compliance Events #", "Camera/observation", "Safety"],
  ["Distracted Driving Events / 10k Miles", "Camera AI events", "Safety"],
  ["Coachable Events Closed %", "Coaching closure", "Safety"],
  ["Coaching Cycle Time (days)", "Event to coach", "Safety"],
  ["High-Risk Driver Count", "Drivers in high-risk tier", "Safety"],
  ["High-Risk Driver Exit Rate", "Exits from high-risk", "Safety"],
  ["Average Claim Severity $ (AL)", "Auto liability severity", "Safety"],
  ["AL Claims Frequency / Million Miles", "AL frequency", "Safety"],
  ["Cargo Claims Frequency / 1000 Loads", "Cargo frequency", "Safety"],
  ["Cargo Claims $ as % Revenue", "Cargo cost ratio", "Safety"],
  ["Physical Damage Loss $", "PD losses", "Safety"],
  ["Workers Comp Claims Frequency", "WC frequency", "Safety"],
  ["Workers Comp Severity $", "WC cost", "Safety"],
  ["Insurance Loss Ratio", "Losses ÷ premium", "CFO"],
  ["Open Claims Count", "Active claims", "Safety"],
  ["Average Claim Close Time (days)", "Cycle time", "Safety"],
  ["Subrogation Recovery $", "Recoveries", "Safety"],
  ["Litigation Matter Count", "Open suits", "Legal"],
  ["Near-Miss Reports #", "Reports filed", "Safety"],
  ["Near-Miss Reports per 100 Drivers", "Reporting culture", "Safety"],
  ["Corrective Action Closure %", "CAPA closed on time", "Safety"],
  ["Corrective Action Cycle Time (days)", "CAPA speed", "Safety"],
  ["Incident Investigation Quality Score", "Audit of investigations", "Safety"],
  ["Drug Test Positivity Rate", "Positives ÷ tests", "Safety"],
  ["Random Testing Completion On-Time %", "Program compliance", "Safety"],
  ["Reasonable Suspicion Tests #", "RS usage", "Safety"],
  ["Training Completion % (required)", "Compliance training", "Safety"],
  ["Defensive Driving Training Currency %", "Training freshness", "Safety"],
  ["Road Test Fail Rate %", "Hiring standard", "Safety"],
  ["Brake Violation Rate", "Inspection brake issues", "Safety"],
  ["Lighting Violation Rate", "Lighting defects", "Safety"],
  ["Tire Violation Rate", "Tire defects at roadside", "Safety"],
  ["Maintenance-Related Crash %", "Crashes with maint factor", "Safety"],
  ["Accident Rate Drivers <1 Year Tenure", "New driver risk", "Safety"],
  ["Night Accident Share %", "Time-of-day risk", "Safety"],
  ["Weather-Related Accident Share %", "Weather risk", "Safety"],
  ["Rear-End Accident Share %", "Accident type mix", "Safety"],
  ["Rollover / Jackknife Count", "Severe event types", "Safety"],
  ["Camera Coverage % of Fleet", "Fleet equipped", "Safety"],
  ["Telematics Coverage % of Fleet", "Fleet equipped", "Safety"],
  ["Safety Observation / Ride-Along Count", "Field presence", "Safety"],
  ["Safety Managers per 100 Drivers", "Resourcing", "Safety"],
  ["DOT Audit Findings Open #", "Open findings", "Safety"],
  ["DataQs Success Rate %", "Violation challenges won", "Safety"],
  ["Policy Acknowledgment %", "Signed policies", "Safety"],
  ["Critical Incident Response Drills #", "Preparedness", "Safety"],
  ["Cargo Theft Incidents #", "Security", "Safety"],
  ["Seal Protocol Compliance %", "Seal process", "Safety"],
  ["Yard Security Incidents #", "Premises security", "Safety"],
  ["Shop OSHA Recordables #", "Shop safety", "Safety"],
  ["Preventability Agreement Rate", "Consistent determinations", "Safety"],
  ["Safety Bonus / Incentive Payout Integrity Score", "Gaming check", "Safety"],
  ["Customer Safety Scorecard Average", "Shipper scores", "Safety"],
  ["Insurance Carrier Risk Rating / Tier", "Underwriting view", "Safety"],
];
safetyMetrics.forEach(([n, d, o]) => metricSeed.push(M("Safety & Compliance", n, d, o)));

const maintMetricList = [
  ["Average Tractor Age (years)", "Power unit age", "Maint"],
  ["Average Trailer Age (years)", "Trailer age", "Maint"],
  ["Fleet Age Distribution % >5 Years", "Aging share", "Maint"],
  ["Maintenance CPM", "Maint cost per mile", "Maint"],
  ["Maintenance CPM by Age Band 0-3", "Young fleet cost", "Maint"],
  ["Maintenance CPM by Age Band 3-6", "Mid age cost", "Maint"],
  ["Maintenance CPM by Age Band 6+", "Old fleet cost", "Maint"],
  ["Parts Cost per Mile", "Parts only CPM", "Maint"],
  ["Labor Cost per Mile (shop)", "Labor CPM", "Maint"],
  ["Outside Repair % of Maint Spend", "Vendor dependency", "Maint"],
  ["Road Call Rate / Million Miles", "On-road failures", "Maint"],
  ["Tow Events #", "Tows", "Maint"],
  ["Average Downtime Days per Repair", "Time out of service", "Maint"],
  ["Deadline Count", "Currently deadlined", "Maint"],
  ["Deadline % of Fleet", "Unavailable share", "Maint"],
  ["PM Compliance %", "On-time PM", "Maint"],
  ["PM Overdue Count", "Backlog", "Maint"],
  ["A/B/C PM On-Time %", "By PM type", "Maint"],
  ["Comeback / Rework Rate %", "Repair quality", "Maint"],
  ["Mean Time Between Failures (hours/miles)", "Reliability", "Maint"],
  ["Mean Time to Repair", "Repair speed", "Maint"],
  ["Shop Backlog (days)", "Queue", "Maint"],
  ["Bay Utilization %", "Shop capacity use", "Maint"],
  ["Tech Productivity (hours billed/available)", "Labor efficiency", "Maint"],
  ["Tech Headcount vs Plan", "Staffing", "Maint"],
  ["Tech Turnover %", "Shop retention", "Maint"],
  ["Parts Inventory $", "Stock value", "Maint"],
  ["Parts Inventory Turns", "Turns", "Maint"],
  ["Parts Fill Rate % (A items)", "Critical availability", "Maint"],
  ["Parts Stockout Events #", "Stockouts", "Maint"],
  ["Obsolete Parts $", "Dead stock", "Maint"],
  ["Warranty Recovery $", "Recovered warranty", "Maint"],
  ["Warranty Recovery Rate %", "Of eligible", "Maint"],
  ["Vendor Invoice Audit Exception %", "Billing errors found", "Maint"],
  ["Tire CPM", "Tire cost", "Maint"],
  ["Tire Road Failure Rate", "Road tire fails", "Maint"],
  ["Retread % of Tire Program", "Retread usage", "Maint"],
  ["Average Tread Life Miles", "Tire life", "Maint"],
  ["Brake Cost per Mile", "Brake economics", "Maint"],
  ["Aftertreatment Downtime Events #", "DPF/SCR issues", "Maint"],
  ["DEF System Failure Events #", "DEF issues", "Maint"],
  ["Engine Oil Analysis Exceptions #", "Oil program", "Maint"],
  ["Campaign / Recall Completion %", "Recall closure", "Maint"],
  ["Annual Inspection Pass Rate (trailers)", "FHWA quality", "Maint"],
  ["Trailer Defect Rate (doors/floors/roofs)", "Claim-related defects", "Maint"],
  ["Reefer Unit Failure Rate", "Reefer reliability", "Maint"],
  ["Reefer Pre-trip Temp Compliance %", "Process compliance", "Maint"],
  ["Asset Register Accuracy %", "Book vs physical", "Maint"],
  ["Units Beyond Economic Repair #", "Should-retire units", "Maint"],
  ["Average Cost of Problem 10% Units", "Worst asset cost", "Maint"],
  ["Spare Tractor Utilization %", "Spare pool use", "Maint"],
  ["Spec Compliance on New Orders %", "Spec discipline", "Maint"],
  ["Average CapEx per New Tractor", "Acquisition cost", "Maint"],
  ["Life-to-Date Maint $ by Unit (top decile)", "Problem unit spend", "Maint"],
  ["Mobile Maintenance Jobs #", "Field service", "Maint"],
  ["Shop Environmental Incidents #", "Spills/violations", "Maint"],
  ["Tooling / Diagnostic Uptime %", "Shop tools ready", "Maint"],
  ["OEM Goodwill Recovery $", "Goodwill credits", "Maint"],
  ["Average Parts Wait Hours", "Wait for parts", "Maint"],
  ["Scheduled vs Unscheduled Maint Mix", "Work mix", "Maint"],
  ["Driver Write-up Closure Time (hrs)", "DVIR response", "Maint"],
  ["Safety-Sensitive Defect Escape Rate", "Defects found roadside not shop", "Maint"],
];
maintMetricList.forEach(([n, d, o]) => metricSeed.push(M("Fleet & Maintenance", n, d, o)));

const techMetrics = [
  ["TMS Uptime %", "Core TMS availability", "IT"],
  ["ELD Platform Uptime %", "ELD availability", "IT"],
  ["Payroll System Uptime %", "Payroll availability", "IT"],
  ["Critical Incident Count (P1)", "Sev1 outages", "IT"],
  ["Mean Time to Recover (MTTR) hours", "Recovery speed", "IT"],
  ["RTO Achievement %", "Met recovery objectives", "IT"],
  ["Backup Restore Test Success %", "Restore tested", "IT"],
  ["MFA Coverage %", "Accounts with MFA", "IT"],
  ["Privileged Accounts Reviewed %", "Admin hygiene", "IT"],
  ["Access Revocation Timeliness (hrs)", "Leaver access kill time", "IT"],
  ["Phishing Fail Rate %", "Simulated phish fails", "IT"],
  ["Security Patches On-Time %", "Patch SLA", "IT"],
  ["Vulnerabilities Open (critical)", "Open critical CVEs", "IT"],
  ["Pen Test Findings Open #", "Open pen findings", "IT"],
  ["Cyber Incidents #", "Security incidents", "IT"],
  ["EDI Error Rate %", "Failed EDI transactions", "IT"],
  ["Integration Failure Rate %", "Failed sync jobs", "IT"],
  ["Data Reconciliation Exceptions / Week", "Cross-system mismatches", "IT"],
  ["Duplicate Master Data Records #", "Data quality", "IT"],
  ["Lane P&L Query Time (minutes)", "Time to insight", "IT"],
  ["% Loads Touchless to Invoice", "Automation depth", "IT"],
  ["Manual Spreadsheet Processes # (critical)", "Shadow process count", "IT"],
  ["Software Seat Utilization %", "Used seats", "IT"],
  ["Software Spend % of Revenue", "Tech cost intensity", "IT"],
  ["IT Ticket Backlog Age (days p50)", "Support lag", "IT"],
  ["IT Ticket CSAT", "User satisfaction", "IT"],
  ["Driver App Crash Rate", "Mobile stability", "IT"],
  ["Driver App Store Rating", "UX proxy", "IT"],
  ["User Adoption % (last major tool)", "Adoption", "IT"],
  ["Alert Fatigue Index (alerts/driver/day)", "Telematics noise", "IT"],
  ["POD OCR Success Rate %", "Doc capture", "IT"],
  ["eBilling Adoption % Customers", "Digital invoice", "IT"],
  ["API Uptime for Customer Visibility", "Customer tech SLA", "IT"],
  ["Change Failure Rate %", "Bad releases", "IT"],
  ["Unauthorized Shadow IT Apps #", "Shadow IT", "IT"],
  ["Data Lake / Warehouse Freshness (hrs)", "Analytics lag", "IT"],
  ["Report Definition Conflicts #", "Metric definition fights", "IT"],
  ["Vendor SLA Credits Recovered $", "Vendor accountability", "IT"],
  ["Disaster Recovery Test Age (days)", "Since last DR test", "IT"],
  ["Ransomware Tabletop Age (days)", "Exercise recency", "IT"],
];
techMetrics.forEach(([n, d, o]) => metricSeed.push(M("Technology & Process", n, d, o)));

const otherMetrics = [
  ["Brokered Load On-Time %", "Broker service", "Brokerage"],
  ["Carrier Fraud Attempts Caught #", "Fraud defense", "Brokerage"],
  ["Active Carrier Network Count (90-day)", "Network depth", "Brokerage"],
  ["Carrier On-Time Score Average", "Carrier quality", "Brokerage"],
  ["Double-Broker Incidents #", "Compliance risk", "Brokerage"],
  ["Broker Margin per Load $", "Unit economics", "Brokerage"],
  ["Broker Loads per Broker per Week", "Productivity", "Brokerage"],
  ["Purchased Transportation as % Revenue", "Buy cost intensity", "Brokerage"],
  ["Fuel Network Compliance %", "On-network gallons", "Procurement"],
  ["Fuel Price Variance vs Benchmark", "Fuel cost quality", "Procurement"],
  ["Off-Network Fuel %", "Leakage", "Procurement"],
  ["Fuel Card Exception Rate", "Control exceptions", "Procurement"],
  ["DEF Cost per Mile", "DEF economics", "Procurement"],
  ["Toll Cost vs Optimal Route Index", "Toll efficiency", "Procurement"],
  ["Vendor Invoice Audit Coverage %", "Audit reach", "Procurement"],
  ["Maverick Spend %", "Off-contract spend", "Procurement"],
  ["Contracted Savings Realized %", "Savings to P&L", "Procurement"],
  ["Critical Vendor Dual-Source %", "Supply risk", "Procurement"],
  ["Dedicated Account Operating Margin %", "Dedicated profit", "Dedicated"],
  ["Dedicated Asset Utilization %", "Dedicated use", "Dedicated"],
  ["Dedicated Scope Creep Events #", "Out-of-scope work", "Dedicated"],
  ["Dedicated Penalty $ Paid", "Service penalties", "Dedicated"],
  ["Dedicated Volume vs Contract Band %", "Volume adherence", "Dedicated"],
  ["OO Capacity Mix %", "OO share of trucks", "OO"],
  ["OO Settlement Dispute Rate", "OO pay issues", "OO"],
  ["OO Average Weekly Miles", "OO utilization", "OO"],
  ["Lease-Purchase Default Rate", "Program risk", "OO"],
  ["OO Safety Event Rate vs Company", "Parity", "OO"],
  ["Contractor Classification Risk Score", "Legal risk index", "Legal"],
  ["Open Litigation Reserve Adequacy %", "Reserve vs expected", "Legal"],
  ["MSA Execution Rate (top customers)", "Contracts signed", "Legal"],
  ["Toxic Indemnity Clauses Accepted #", "Contract risk", "Legal"],
  ["Third-Party Carrier Vet Failures Caught #", "Vetting", "Legal"],
  ["Document Retention Compliance Sample %", "Retention audits", "Legal"],
  ["CO2e per Mile (estimated)", "Emissions intensity", "ESG"],
  ["Gallons Saved via Idle Reduction", "Idle program", "ESG"],
  ["Aero Device Equipped %", "Aero adoption", "ESG"],
  ["Customer Carbon Reports Delivered On-Time %", "ESG service", "ESG"],
  ["Alternative Fuel Miles %", "Energy transition", "ESG"],
  ["Terminal OR Spread (best-worst bps)", "Network variance", "Regional"],
  ["Terminals Below OR Target %", "Underperformers", "Regional"],
  ["Inter-Terminal Empty Share %", "Balance quality", "Regional"],
  ["Facility Condition Index", "Asset condition", "Facilities"],
  ["Yard Capacity Utilization %", "Yard crowding", "Facilities"],
  ["Driver Facility Satisfaction Score", "Amenities", "Facilities"],
  ["Security Incidents at Facilities #", "Site security", "Facilities"],
  ["Training Completion to Standard %", "Academy output", "Training"],
  ["Post-Training Skill Assessment Pass %", "Learning quality", "Training"],
  ["Remedial Training Trigger Rate", "Retraining need", "Training"],
  ["CI Projects Completed #", "Improvement throughput", "Quality"],
  ["CI Hard Savings $ Verified in P&L", "Real savings", "Quality"],
  ["Recurring Defect Rate (top 5 issues)", "Repeat failures", "Quality"],
  ["Root Cause Analysis Completion %", "RCA discipline", "Quality"],
  ["Standard Work Audit Pass %", "Process control", "Quality"],
  ["Brand Mention Sentiment Score", "Reputation", "Comms"],
  ["Crisis Comms Playbook Test Age (days)", "Preparedness", "Comms"],
  ["Internal Comms Open Rate (drivers)", "Message reach", "Comms"],
  ["Executive Skip-Level Sessions # / Qtr", "Leadership presence", "CEO"],
  ["Board Risk Items Red #", "Enterprise risk", "CEO"],
  ["Strategy Initiative On-Track %", "Strategy execution", "CEO"],
  ["Decision Cycle Time (key decisions days)", "Speed of decisions", "CEO"],
  ["Heroics Index (after-hours critical pages)", "System fragility", "COO"],
];
otherMetrics.forEach(([n, d, o]) => metricSeed.push(M("Cross-Functional & Strategic", n, d, o)));

function expandMetricsToThousand(seed) {
  const out = seed.slice();
  const existing = new Set(out.map(m => m.name.toLowerCase()));

  const prefixes = [
    "Trailing 4-Week", "Trailing 13-Week", "Month-to-Date", "Quarter-to-Date", "Year-to-Date",
    "YoY Change in", "WoW Change in", "MoM Change in", "Terminal-Level", "Fleet-Type",
    "Company Driver", "Owner-Operator", "Dry Van", "Reefer", "Flatbed", "Dedicated",
    "Spot", "Contract", "Regional", "Long-Haul", "Team", "Solo", "Night-Shift", "Weekend"
  ];

  const suffixes = [
    "Target Attainment %", "Variance to Budget", "Variance to Forecast", "Best Terminal",
    "Worst Terminal", "Top Quartile Gap", "Peer Benchmark Delta", "13-Week Trend Slope",
    "Alert Threshold Breaches #", "Days Red This Quarter", "Owner Action Plans Open #"
  ];

  const baseNames = seed.map(m => m.name);
  const categories = [...new Set(seed.map(m => m.category))];
  const owners = ["CFO", "COO", "CRO", "CHRO", "Safety", "IT", "Maint", "Legal", "CEO"];

  let i = 0;
  while (out.length < 1000 && i < 100000) {
    i++;
    const base = seed[i % seed.length];
    const mode = i % 3;
    let name, definition, category, owner;
    if (mode === 0) {
      const p = prefixes[i % prefixes.length];
      name = `${p} ${base.name}`;
      definition = `${p} view of: ${base.definition}`;
      category = base.category;
      owner = base.owner;
    } else if (mode === 1) {
      const s = suffixes[i % suffixes.length];
      name = `${base.name} — ${s}`;
      definition = `${s} applied to ${base.name}. ${base.definition}`;
      category = base.category;
      owner = base.owner;
    } else {
      const p = prefixes[(i * 3) % prefixes.length];
      const s = suffixes[(i * 5) % suffixes.length];
      name = `${p} ${base.name} (${s})`;
      definition = `Segmented/derivative metric: ${p}; ${s}. Base: ${base.definition}`;
      category = base.category;
      owner = base.owner;
    }
    const key = name.toLowerCase();
    if (!existing.has(key)) {
      existing.add(key);
      out.push(M(category, name, definition, owner));
    }
  }

  // Absolute final fillers if needed (should not be)
  let n = 1;
  while (out.length < 1000) {
    const name = `Enterprise Scorecard Metric ${n}`;
    if (!existing.has(name.toLowerCase())) {
      existing.add(name.toLowerCase());
      out.push(M("Cross-Functional & Strategic", name, "Placeholder reserved metric slot for custom owner KPI", "CEO"));
      n++;
    } else n++;
  }

  return out.slice(0, 1000);
}

// ============================================================================
// BUILD DOCUMENT
// ============================================================================

const questions = expandToThousand(questionBank);
const metrics = expandMetricsToThousand(metricSeed);

console.log("Questions:", questions.length, "unique check sample:", questions[0].text.slice(0, 40));
console.log("Metrics:", metrics.length);
console.log("Seed questions before expand:", questionBank.length);
console.log("Seed metrics before expand:", metricSeed.length);

// Group questions by role preserving order
function groupQuestions(qs) {
  const map = new Map();
  for (const q of qs) {
    if (!map.has(q.role)) map.set(q.role, []);
    map.get(q.role).push(q.text);
  }
  return map;
}

function groupMetrics(ms) {
  const map = new Map();
  for (const m of ms) {
    if (!map.has(m.category)) map.set(m.category, []);
    map.get(m.category).push(m);
  }
  return map;
}

const qGroups = groupQuestions(questions);
const mGroups = groupMetrics(metrics);

function p(text, opts = {}) {
  return new Paragraph({
    spacing: { after: opts.after ?? 100, before: opts.before ?? 0 },
    alignment: opts.align,
    children: [new TextRun({
      text, font: "Arial", size: opts.size ?? 20, bold: opts.bold,
      color: opts.color ?? DARK, italics: opts.italics
    })]
  });
}

function h1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: { before: 280, after: 160 },
    border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: ACCENT, space: 4 } },
    children: [new TextRun({ text, font: "Arial", size: 28, bold: true, color: NAVY })]
  });
}

function h2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: { before: 220, after: 100 },
    children: [new TextRun({ text, font: "Arial", size: 24, bold: true, color: STEEL })]
  });
}

function metricRow(num, name, definition, owner) {
  const cellMargin = { top: 40, bottom: 40, left: 60, right: 60 };
  const headerFill = num === 0 ? NAVY : (num % 2 === 0 ? LIGHT_GRAY : "FFFFFF");
  const textColor = num === 0 ? "FFFFFF" : DARK;
  const bold = num === 0;
  const size = num === 0 ? 16 : 15;

  return new TableRow({
    children: [
      new TableCell({
        borders, width: { size: 500, type: WidthType.DXA },
        shading: { fill: headerFill, type: ShadingType.CLEAR }, margins: cellMargin,
        children: [new Paragraph({ children: [new TextRun({ text: String(num === 0 ? "#" : num), font: "Arial", size, bold, color: textColor })] })]
      }),
      new TableCell({
        borders, width: { size: 2800, type: WidthType.DXA },
        shading: { fill: headerFill, type: ShadingType.CLEAR }, margins: cellMargin,
        children: [new Paragraph({ children: [new TextRun({ text: name, font: "Arial", size, bold: true, color: textColor })] })]
      }),
      new TableCell({
        borders, width: { size: 4660, type: WidthType.DXA },
        shading: { fill: headerFill, type: ShadingType.CLEAR }, margins: cellMargin,
        children: [new Paragraph({ children: [new TextRun({ text: definition, font: "Arial", size, bold, color: textColor })] })]
      }),
      new TableCell({
        borders, width: { size: 1400, type: WidthType.DXA },
        shading: { fill: headerFill, type: ShadingType.CLEAR }, margins: cellMargin,
        children: [new Paragraph({ children: [new TextRun({ text: owner, font: "Arial", size, bold, color: textColor })] })]
      }),
    ]
  });
}

const children = [];

// Cover
children.push(new Paragraph({ spacing: { before: 800 }, children: [] }));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { after: 160 },
  children: [new TextRun({ text: "THE OWNER'S PLAYBOOK — EXPANDED EDITION", font: "Arial", size: 18, bold: true, color: ACCENT, characterSpacing: 120 })]
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { after: 200 },
  border: { bottom: { style: BorderStyle.SINGLE, size: 18, color: ACCENT, space: 10 } },
  children: [new TextRun({ text: "1,000 Questions. 1,000 Metrics.", font: "Arial", size: 40, bold: true, color: NAVY })]
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { before: 240, after: 100 },
  children: [new TextRun({ text: "How a Seasoned Trucking Company Owner Holds the Full C-Suite Accountable", font: "Arial", size: 22, color: STEEL })]
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { before: 200 },
  children: [new TextRun({ text: "Asset carriers · Hybrid brokerage · Dedicated · Regional & national fleets", font: "Arial", size: 18, color: MUTED, italics: true })]
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { before: 400 },
  children: [new TextRun({ text: "Leadership reviews · Board packs · Monthly operating cadence · Due diligence", font: "Arial", size: 16, color: "888888" })]
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { before: 60, after: 200 },
  children: [new TextRun({ text: "July 2026", font: "Arial", size: 16, color: "888888" })]
}));

children.push(new Paragraph({ children: [new PageBreak()] }));

// Intro
children.push(h1("How to Use This Expanded Playbook"));
children.push(p("This is the full field manual. One thousand questions and one thousand metrics—not because you will ask all of them every week, but because excellence in trucking is a thousand small truths, not five vanity KPIs on a poster."));
children.push(p("Use it three ways:"));
children.push(p("1. Monthly deep dives — pick one function, run 20–40 questions, demand evidence.", { after: 60 }));
children.push(p("2. Scorecard design — select 30–50 metrics for the executive dashboard; keep the rest as diagnostic drills when something turns red.", { after: 60 }));
children.push(p("3. Due diligence / turnarounds — walk the list systematically when buying a fleet, replacing a VP, or stopping a bleed.", { after: 120 }));
children.push(p("Cadence still matters: weekly flash (cash, safety, seats, service), monthly full scorecard, quarterly strategy and capital, annual board-level risk and culture.", { after: 80 }));
children.push(p("Rule of the house: No metric without an owner. No red metric without a 30-day action. No answer without a number when a number exists.", { italics: true, color: MUTED, after: 160 }));
children.push(p(`This edition contains exactly ${questions.length} questions across ${qGroups.size} role areas and ${metrics.length} metrics across ${mGroups.size} categories.`, { bold: true, after: 200 }));

children.push(new Paragraph({ children: [new PageBreak()] }));

// Part 1
children.push(h1("Part One — 1,000 Questions for Leadership"));
children.push(p("Ask in person when stakes are high. Watch who looks at whom. Demand data, not theater.", { italics: true, color: MUTED, after: 160 }));

let qNum = 1;
for (const [role, list] of qGroups) {
  children.push(h2(`${role} (${list.length} questions)`));
  for (const text of list) {
    children.push(new Paragraph({
      numbering: { reference: "q-numbers", level: 0 },
      spacing: { after: 48, before: 24 },
      children: [new TextRun({ text, font: "Arial", size: 18, color: DARK })]
    }));
    qNum++;
  }
}

children.push(new Paragraph({ children: [new PageBreak()] }));

// Part 2
children.push(h1("Part Two — 1,000 Metrics for the Owner's Wall"));
children.push(p("Define once. Assign an owner. Set a target. Review the trend. Act on red. Derivative metrics (trailing periods, segments, variance-to-budget) exist so you can drill from enterprise green to local red without inventing math in a panic.", { italics: true, color: MUTED, after: 160 }));

let mNum = 1;
for (const [cat, list] of mGroups) {
  children.push(h2(`${cat} (${list.length} metrics)`));
  const rows = [metricRow(0, "Metric", "Definition / Why It Matters", "Owner")];
  // Split huge tables into chunks of 40 for Word stability
  const chunkSize = 40;
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    rows.push(metricRow(mNum, m.name, m.definition, m.owner));
    mNum++;
    if (rows.length >= chunkSize + 1 || i === list.length - 1) {
      children.push(new Table({
        width: { size: 9360, type: WidthType.DXA },
        columnWidths: [500, 2800, 4660, 1400],
        rows: rows.splice(0, rows.length) // take all; we'll rebuild header for next chunk
      }));
      if (i < list.length - 1) {
        rows.push(metricRow(0, "Metric", "Definition / Why It Matters", "Owner"));
      }
      children.push(p("", { after: 120 }));
    }
  }
}

children.push(new Paragraph({ children: [new PageBreak()] }));
children.push(h1("Closing Word from the Owner's Chair"));
children.push(p("A thousand questions will not save a carrier that will not face bad news. A thousand metrics will not save a carrier that will not fire bad freight, fix bad processes, or exit bad actors."));
children.push(p("Start Monday with five: operating ratio, free cash flow, empty-mile percentage, preventable accidents per million miles, and driver turnover. When one turns red, use this book to interrogate the function that owns it until the root cause has a name, an owner, and a date."));
children.push(p("Run the questions. Trust the metrics. Protect the downside. Earn the upside.", { bold: true, color: NAVY, size: 22, after: 200 }));
children.push(p("— A seasoned carrier owner who has seen both sides of the ledger", { italics: true, color: MUTED, align: AlignmentType.RIGHT }));

const doc = new Document({
  styles: {
    default: { document: { run: { font: "Arial", size: 20 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, font: "Arial", color: NAVY },
        paragraph: { spacing: { before: 280, after: 160 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, font: "Arial", color: STEEL },
        paragraph: { spacing: { before: 220, after: 100 }, outlineLevel: 1 } },
    ]
  },
  numbering: {
    config: [{
      reference: "q-numbers",
      levels: [{
        level: 0, format: LevelFormat.DECIMAL, text: "%1.",
        alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 576, hanging: 360 } } }
      }]
    }]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 900, right: 900, bottom: 900, left: 900 }
      }
    },
    headers: {
      default: new Header({
        children: [new Paragraph({
          border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: NAVY, space: 4 } },
          spacing: { after: 80 },
          children: [
            new TextRun({ text: "TRUXON  ·  Owner's Playbook — 1,000 / 1,000 Edition", font: "Arial", size: 14, color: MUTED }),
            new TextRun({ text: "  ·  Confidential", font: "Arial", size: 14, color: "999999", italics: true }),
          ]
        })]
      })
    },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          border: { top: { style: BorderStyle.SINGLE, size: 6, color: "CCCCCC", space: 4 } },
          spacing: { before: 60 },
          alignment: AlignmentType.CENTER,
          children: [
            new TextRun({ text: "Page ", font: "Arial", size: 14, color: MUTED }),
            new TextRun({ children: [PageNumber.CURRENT], font: "Arial", size: 14, color: MUTED }),
            new TextRun({ text: " of ", font: "Arial", size: 14, color: MUTED }),
            new TextRun({ children: [PageNumber.TOTAL_PAGES], font: "Arial", size: 14, color: MUTED }),
            new TextRun({ text: "  ·  Ask hard questions. Verify with numbers.", font: "Arial", size: 14, color: "999999", italics: true }),
          ]
        })]
      })
    },
    children
  }]
});

Packer.toBuffer(doc).then(buffer => {
  const out = "/home/ilker/src/truxon/Trucking_CSuite_Owner_Playbook_1000.docx";
  fs.writeFileSync(out, buffer);
  console.log("Wrote:", out, "size MB:", (buffer.length / 1024 / 1024).toFixed(2));
  // verify counts in numbering
  console.log("Final qNum expected 1001 (1-based end):", qNum);
  console.log("Final mNum expected 1001:", mNum);
}).catch(err => {
  console.error(err);
  process.exit(1);
});
