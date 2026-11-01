/* =============================================================================
   TEESSIDE LETTINGS: SQL ANALYSIS
   =============================================================================
   Author    : Anthony Ayumu
   Database  : teesside_lettings (MySQL 8.x)
   Setup     : teesside_lettings_mysql_setup.sql (creates and populates the tables)

   PURPOSE
   Fourteen business questions for a fictional Teesside letting agency, answered
   with SQL. Part 1 covers joins, aggregation and conditional counting. Part 2
   covers CTEs and window functions (LAG, RANK, running totals, PARTITION BY).

   SCHEMA (8 tables)
     branches              4 rows     agency branches
     landlords             60 rows    landlord_type, management_fee_pct
     properties            180 rows   landlord_id -> landlords, branch_id -> branches
     tenants               420 rows   employment_status, referral_source
     tenancies             317 rows   property_id -> properties, tenant_id -> tenants
     rent_payments                    tenancy_id -> tenancies
     viewings                         property_id -> properties, tenant_id -> tenants
     maintenance_requests  464 rows   property_id -> properties

   KEY JOIN PATHS
     branches -> properties -> tenancies -> rent_payments
     landlords -> properties -> maintenance_requests
     tenants -> tenancies -> rent_payments

   CONVENTIONS AND ASSUMPTIONS (apply throughout)
     - "As of" date for arrears and late-payment questions: 2025-09-30,
       the latest due date in the data.
     - Money columns are in GBP. Rates are rounded to 1 or 2 decimal places.
     - Every result was reconciled against a source total (for example 180
       properties, 464 maintenance requests) to confirm that joins did not
       duplicate or drop rows.
     - Where a plain column is selected next to an aggregate, it is also listed
       in GROUP BY so the queries run under ONLY_FULL_GROUP_BY.
     - Exploratory SELECT * statements are at the end and are commented out.

   CONTENTS
     Part 1: Joins, aggregation and conditional counts
       Q1   Properties and average listed rent per branch
       Q2   Average listed rent by property type and bedrooms
       Q3   Referral sources that bring in signed tenants
       Q4   Current occupancy per branch
       Q5   Viewing-to-application conversion by property type
       Q6   Management fees earned per landlord type
       Q7   Arrears report for Active tenancies
       Q8   Late payment rate by tenant employment status
     Part 2: CTEs and window functions
       Q9   Repair requests and spend per property by EPC rating
       Q10  Monthly rent collected, running total and % change
       Q11  Void periods by town
       Q12  Top 3 most expensive properties to maintain per branch
       Q13  Maintenance SLA compliance per branch and priority
       Q14  Landlord scorecard with ranking and bottom-10 flag
   ============================================================================= */

use teesside_lettings;


/* #############################################################################
   PART 1: JOINS, AGGREGATION AND CONDITIONAL COUNTS
   ############################################################################# */


-- -----------------------------------------------------------------------------
-- Q1. How many properties does each branch manage, and what is the average
--     listed rent at each?
-- Tables    : branches, properties
-- Technique : INNER JOIN, COUNT, AVG, GROUP BY
-- Notes     : One row per branch. Counts across branches add up to 180.
-- -----------------------------------------------------------------------------
select
    branches.branch_name,
    branches.branch_id,
    count(properties.property_id) as total_properties,
    round(avg(properties.listed_rent_pcm), 2) as average_rent_prices
from branches
join properties
    on branches.branch_id = properties.branch_id
group by branches.branch_id, branches.branch_name
order by average_rent_prices desc;


-- -----------------------------------------------------------------------------
-- Q2. Average listed rent by property type and bedrooms, cheapest first.
-- Tables    : properties
-- Technique : GROUP BY on two columns
-- Notes     : One row per type/bedroom combination. n shows the sample size,
--             and the n values add up to 180.
-- -----------------------------------------------------------------------------
select
    properties.property_type,
    properties.bedrooms,
    count(*) as n,
    round(avg(properties.listed_rent_pcm), 2) as average_rent_prices
from properties
group by properties.property_type, properties.bedrooms
order by average_rent_prices asc;


-- -----------------------------------------------------------------------------
-- Q3. Which referral sources bring in the most tenants who actually end up
--     signing a tenancy?
-- Tables    : tenants, tenancies
-- Technique : COUNT(DISTINCT), INNER JOIN
-- Notes     : DISTINCT counts each tenant once, even if they have several
--             tenancies. A plain COUNT(*) would count tenancies instead (317
--             rows rather than 213 tenants). Any tenancy status counts as
--             "signed". This ranks volume, not conversion rate.
-- -----------------------------------------------------------------------------
select
    tenants.referral_source,
    count(distinct tenants.tenant_id) as n
from tenants
join tenancies
    on tenants.tenant_id = tenancies.tenant_id
group by tenants.referral_source
order by n desc;


-- -----------------------------------------------------------------------------
-- Q4. Current occupancy: what share of each branch's properties has an Active
--     tenancy right now?
-- Tables    : branches, properties, tenancies
-- Technique : LEFT JOIN, conditional COUNT(DISTINCT CASE ...)
-- Notes     : LEFT JOIN to tenancies keeps vacant properties in the
--             denominator. Filtering on status in a WHERE clause would remove
--             them and overstate occupancy. Part / whole * 100. Total = 180
--             properties, 156 occupied.
-- -----------------------------------------------------------------------------
select
    branches.branch_id,
    branches.branch_name,
    count(distinct properties.property_id) as all_properties,
    count(distinct case when tenancies.status = 'Active'
                        then properties.property_id end) as active_properties,
    round(count(distinct case when tenancies.status = 'Active'
                              then properties.property_id end)
          / count(distinct properties.property_id) * 100, 1) as property_share_pct
from branches
join properties
    on branches.branch_id = properties.branch_id
left join tenancies
    on properties.property_id = tenancies.property_id
group by branches.branch_id, branches.branch_name
order by property_share_pct desc;


-- -----------------------------------------------------------------------------
-- Q5. Viewing-to-application conversion rate by property type.
--     Which homes are easiest to let?
-- Tables    : properties, viewings
-- Technique : Conditional COUNT, rate calculation
-- Notes     : No-shows are shown separately and EXCLUDED from the denominator,
--             so conversion = applications / attended viewings. Including them
--             would make the rates reflect no-show behaviour too, and changes
--             the ranking.
-- -----------------------------------------------------------------------------
select
    properties.property_type,
    count(viewings.outcome) as all_viewings,
    count(case when viewings.outcome = 'No show'
               then viewings.viewing_id end) as no_shows,
    count(case when viewings.outcome <> 'No show'
               then viewings.viewing_id end) as attended_viewings,
    count(case when viewings.outcome = 'Applied'
               then viewings.viewing_id end) as applications,
    round(count(case when viewings.outcome = 'Applied' then viewings.viewing_id end)
          / count(case when viewings.outcome <> 'No show' then viewings.viewing_id end)
          * 100, 2) as conversion_rate_pct
from properties
join viewings
    on properties.property_id = viewings.property_id
group by properties.property_type
order by conversion_rate_pct desc;


-- -----------------------------------------------------------------------------
-- Q6. Agency revenue: total management fees earned per landlord type
--     (rent actually collected x fee %).
-- Tables    : landlords, properties, tenancies, rent_payments
-- Technique : Four-table join, calculation inside SUM
-- Notes     : The fee is applied to each payment BEFORE summing, because
--             management_fee_pct differs by landlord. "Collected" means
--             amount_paid, so unpaid rent earns no fee. All payments to date.
-- -----------------------------------------------------------------------------
select
    landlords.landlord_type,
    round(sum(rent_payments.amount_paid * landlords.management_fee_pct / 100), 2) as fees_collected
from landlords
join properties
    on landlords.landlord_id = properties.landlord_id
join tenancies
    on properties.property_id = tenancies.property_id
join rent_payments
    on tenancies.tenancy_id = rent_payments.tenancy_id
group by landlords.landlord_type
order by fees_collected asc;


-- -----------------------------------------------------------------------------
-- Q7. Arrears report: every Active tenancy owing money, with total owed and
--     number of missed/short payments. Biggest debt first.
-- Tables    : tenancies, rent_payments, tenants
-- Technique : Conditional COUNT and SUM, HAVING
-- Notes     : A payment is "short" when amount_paid < amount_due. Shortfalls
--             are summed only, so overpayments do not offset other months.
--             Only payments due on or before 2025-09-30 are included.
--             WHERE filters rows before grouping. HAVING filters tenancies
--             after grouping. (MySQL allows a SELECT alias in HAVING. Other
--             databases need the full expression.)
-- -----------------------------------------------------------------------------
select
    tenancies.tenancy_id,
    tenants.full_name,
    count(case when rent_payments.amount_due > rent_payments.amount_paid
               then rent_payments.payment_id end) as missed_payments,
    round(sum(case when rent_payments.amount_due > rent_payments.amount_paid
                   then rent_payments.amount_due - rent_payments.amount_paid end), 2) as short_falls
from tenancies
join rent_payments
    on tenancies.tenancy_id = rent_payments.tenancy_id
join tenants
    on tenancies.tenant_id = tenants.tenant_id
where tenancies.status = 'Active'
  and rent_payments.due_date <= '2025-09-30'
group by tenancies.tenancy_id, tenants.full_name
having short_falls > 0
order by short_falls desc, missed_payments desc;


-- -----------------------------------------------------------------------------
-- Q8. Late payment rate by tenant employment status
--     (late = paid more than 3 days after due, or unpaid).
-- Tables    : tenants, tenancies, rent_payments
-- Technique : Conditional COUNT with DATEDIFF, OR ... IS NULL
-- Notes     : DATEDIFF(later, earlier). Unpaid rows (paid_date IS NULL) need
--             their own condition, because DATEDIFF returns NULL for them.
--             Payments due after 2025-09-30 are excluded. All tenancy statuses
--             are included, since this is a historical rate. The rate is per
--             payment, not per tenant.
-- -----------------------------------------------------------------------------
select
    tenants.employment_status,
    count(rent_payments.payment_id) as all_payments,
    count(case when datediff(rent_payments.paid_date, rent_payments.due_date) > 3
                 or rent_payments.paid_date is null
               then rent_payments.payment_id end) as late_payments,
    round(count(case when datediff(rent_payments.paid_date, rent_payments.due_date) > 3
                       or rent_payments.paid_date is null
                     then rent_payments.payment_id end)
          / count(rent_payments.payment_id) * 100, 2) as late_payments_pct
from tenants
join tenancies
    on tenancies.tenant_id = tenants.tenant_id
join rent_payments
    on rent_payments.tenancy_id = tenancies.tenancy_id
where rent_payments.due_date <= '2025-09-30'
group by tenants.employment_status
order by late_payments_pct desc;


/* #############################################################################
   PART 2: CTEs AND WINDOW FUNCTIONS
   ############################################################################# */


-- -----------------------------------------------------------------------------
-- Q9. Maintenance and EPC: average number of repair requests and average repair
--     spend per property, by EPC rating. Does energy efficiency predict repair
--     cost?
-- Tables    : properties, maintenance_requests
-- Technique : Two-stage CTE, LEFT JOIN, COALESCE, LAG, RANK
-- Notes     : Stage 1 gives one row per property. LEFT JOIN from properties
--             keeps properties with no repairs, and COALESCE turns their NULL
--             spend into 0, so the averages are true per-property figures.
--             Stage 2 averages by rating. The final query adds the change vs
--             the previous rating (LAG) and a rank by spend (RANK).
--             CAUTION: ratings A and G contain one property each, so read them
--             with care. Open repairs have no cost recorded and add nothing.
--             The result is an association, not proof of cause.
-- -----------------------------------------------------------------------------
with property_summary as (
    select
        properties.property_id,
        properties.epc_rating,
        count(maintenance_requests.request_id) as requests,
        coalesce(sum(maintenance_requests.cost), 0) as total_spent
    from properties
    left join maintenance_requests
        on properties.property_id = maintenance_requests.property_id
    group by properties.property_id, properties.epc_rating
),
rating_summary as (
    select
        epc_rating,
        count(*) as property_count,
        round(avg(requests), 2) as average_requests,
        round(avg(total_spent), 2) as average_spend
    from property_summary
    group by epc_rating
)
select
    epc_rating,
    property_count,
    average_requests,
    average_spend,
    average_spend - lag(average_spend) over (order by epc_rating) as change_vs_previous,
    rank() over (order by average_spend desc) as rank_by_spend
from rating_summary
order by epc_rating;


-- -----------------------------------------------------------------------------
-- Q10. Month-by-month rent collected across the agency in 2025, with a running
--      total and month-on-month % change.
-- Tables    : rent_payments
-- Technique : CTE, DATE_FORMAT, running SUM() OVER, LAG, NULLIF
-- Notes     : Months are based on paid_date (when cash arrived), not due_date.
--             The label uses %Y-%m so it sorts chronologically. The data covers
--             January to September 2025 only. September may be understated,
--             because rent due then but paid after the data cut-off is not
--             captured. The first month's % change is NULL (no previous month).
--             NULLIF guards against division by zero.
-- -----------------------------------------------------------------------------
with monthly as (
    select
        date_format(rent_payments.paid_date, '%Y-%m') as payment_month,
        sum(rent_payments.amount_paid) as total_payments_collected
    from rent_payments
    where rent_payments.paid_date >= '2025-01-01'
      and rent_payments.paid_date <  '2026-01-01'
    group by date_format(rent_payments.paid_date, '%Y-%m')
)
select
    payment_month,
    total_payments_collected,
    sum(total_payments_collected) over (order by payment_month) as running_total,
    round((total_payments_collected - lag(total_payments_collected) over (order by payment_month))
          / nullif(lag(total_payments_collected) over (order by payment_month), 0)
          * 100, 2) as month_on_month_pct_change
from monthly
order by payment_month;


-- -----------------------------------------------------------------------------
-- Q11. Void periods: for each property, the gap in days between one tenancy
--      ending and the next starting. Which towns have the longest average voids?
-- Tables    : tenancies, properties
-- Technique : LAG with PARTITION BY, CTE, DATEDIFF
-- Notes     : PARTITION BY property_id restarts the window for each property, so
--             a tenancy only looks back at the same property's previous tenancy.
--             Each property's first tenancy has no void (NULL) and is excluded.
--             The window function is calculated in the CTE and filtered in the
--             outer query, because window functions cannot be used in WHERE.
--             Only completed voids are counted. A property empty right now has
--             no "next start date". Town means the property's town.
-- -----------------------------------------------------------------------------
with tenancy_gap as (
    select
        tenancies.property_id,
        properties.town,
        tenancies.tenancy_id,
        tenancies.start_date,
        datediff(
            tenancies.start_date,
            lag(tenancies.end_date) over (
                partition by tenancies.property_id
                order by tenancies.start_date, tenancies.tenancy_id
            )
        ) as void_length_in_days
    from tenancies
    join properties
        on tenancies.property_id = properties.property_id
)
select
    town,
    count(void_length_in_days) as number_of_voids,
    round(avg(void_length_in_days), 1) as average_void_length,
    max(void_length_in_days) as longest_void
from tenancy_gap
where void_length_in_days is not null
group by town
order by average_void_length desc;


-- -----------------------------------------------------------------------------
-- Q12. Top 3 most expensive properties to maintain in each branch (use RANK).
-- Tables    : branches, properties, maintenance_requests
-- Technique : Two-stage CTE, RANK() OVER (PARTITION BY ...)
-- Notes     : "Expensive" = total repair spend per property. PARTITION BY
--             branch_id restarts the ranking for each branch. The rank filter
--             sits in an outer query, because WHERE cannot see window results.
--             RANK gives ties the same number, so a branch can return more than
--             3 rows on a tie. Properties with no repairs are excluded (inner
--             join). Open jobs have no cost recorded.
-- -----------------------------------------------------------------------------
with property_cost as (
    select
        branches.branch_id,
        branches.branch_name,
        properties.property_id,
        count(maintenance_requests.request_id) as number_of_requests,
        sum(maintenance_requests.cost) as total_request_cost
    from branches
    join properties
        on branches.branch_id = properties.branch_id
    join maintenance_requests
        on properties.property_id = maintenance_requests.property_id
    group by branches.branch_id, branches.branch_name, properties.property_id
),
ranked as (
    select
        branch_id,
        branch_name,
        property_id,
        number_of_requests,
        total_request_cost,
        rank() over (partition by branch_id order by total_request_cost desc) as branch_ranks
    from property_cost
)
select
    branch_id,
    branch_name,
    property_id,
    number_of_requests,
    total_request_cost,
    branch_ranks
from ranked
where branch_ranks <= 3
order by branch_id, branch_ranks;


-- -----------------------------------------------------------------------------
-- Q13. SLA check: what % of Emergency (fix within 1 day), Urgent (7 days) and
--      Routine (28 days) jobs were resolved on time, per branch?
-- Tables    : branches, properties, maintenance_requests
-- Technique : CTE, CASE to map priority to a target, conditional COUNT
-- Notes     : On time = days between reported and resolved <= the SLA target,
--             so a job fixed on day 1 meets a 1-day target. Open jobs have no
--             resolved date, so they never count as on time (they act as
--             misses). still_open shows how many there are. Emergency groups
--             are small, so read job counts next to the rates.
-- -----------------------------------------------------------------------------
with request_sla as (
    select
        branches.branch_id,
        branches.branch_name,
        maintenance_requests.request_id,
        maintenance_requests.priority,
        case when maintenance_requests.priority = 'Emergency' then 1
             when maintenance_requests.priority = 'Urgent'    then 7
             when maintenance_requests.priority = 'Routine'   then 28
        end as sla_days,
        datediff(maintenance_requests.resolved_date,
                 maintenance_requests.reported_date) as days_taken
    from branches
    join properties
        on branches.branch_id = properties.branch_id
    join maintenance_requests
        on properties.property_id = maintenance_requests.property_id
)
select
    branch_id,
    branch_name,
    priority,
    sla_days,
    count(request_id) as all_jobs,
    count(case when days_taken <= sla_days then request_id end) as jobs_resolved_on_time,
    round(count(case when days_taken <= sla_days then request_id end)
          / count(request_id) * 100, 1) as on_time_rate_pct,
    count(case when days_taken is null then request_id end) as still_open
from request_sla
group by branch_id, branch_name, priority, sla_days
order by branch_id, sla_days;


-- -----------------------------------------------------------------------------
-- Q14. Landlord scorecard: for each landlord, properties, current occupancy %,
--      fees earned, repair spend, and net value to the agency (fees minus 15%
--      of repair spend as admin cost). Rank them and flag the bottom 10.
-- Tables    : landlords, properties, tenancies, rent_payments,
--             maintenance_requests
-- Technique : Multiple CTEs, LEFT JOIN, COALESCE, RANK (ascending and descending)
-- Notes     : Occupancy and fees come through tenancies, and repairs come
--             straight from properties. Joining both branches in one query would
--             repeat each payment once per repair and inflate the totals
--             (fan-out), so each measure is aggregated to one row per landlord
--             first and the results are combined afterwards.
--             COALESCE turns a missing fee or repair total into 0, so landlords
--             without repairs keep a net value.
--             Net value = fees earned - 0.15 * repair spend (15% admin cost).
--             The bottom-10 flag uses an ascending rank, so a tie at 10th
--             could flag more than 10. Net value in pounds favours landlords
--             with larger portfolios.
-- -----------------------------------------------------------------------------
with property_stats as (
    -- one row per landlord: properties and how many are occupied
    select
        landlords.landlord_id,
        count(distinct properties.property_id) as total_properties,
        count(distinct case when tenancies.status = 'Active'
                            then properties.property_id end) as occupied_properties
    from landlords
    left join properties on landlords.landlord_id = properties.landlord_id
    left join tenancies  on properties.property_id = tenancies.property_id
    group by landlords.landlord_id
),
fee_stats as (
    -- one row per landlord: management fees on rent actually collected
    select
        landlords.landlord_id,
        sum(rent_payments.amount_paid * landlords.management_fee_pct / 100) as fees_earned
    from landlords
    join properties    on landlords.landlord_id = properties.landlord_id
    join tenancies     on properties.property_id = tenancies.property_id
    join rent_payments on tenancies.tenancy_id = rent_payments.tenancy_id
    group by landlords.landlord_id
),
repair_stats as (
    -- one row per landlord: total repair spend
    select
        properties.landlord_id,
        sum(maintenance_requests.cost) as repair_spend
    from properties
    join maintenance_requests on properties.property_id = maintenance_requests.property_id
    group by properties.landlord_id
),
scorecard as (
    -- combine the three, one row per landlord
    select
        landlords.landlord_id,
        landlords.full_name,
        landlords.landlord_type,
        coalesce(property_stats.total_properties, 0) as total_properties,
        round(property_stats.occupied_properties
              / nullif(property_stats.total_properties, 0) * 100, 1) as occupancy_pct,
        round(coalesce(fee_stats.fees_earned, 0), 2) as fees_earned,
        round(coalesce(repair_stats.repair_spend, 0), 2) as repair_spend,
        round(coalesce(fee_stats.fees_earned, 0)
              - 0.15 * coalesce(repair_stats.repair_spend, 0), 2) as net_value
    from landlords
    left join property_stats on landlords.landlord_id = property_stats.landlord_id
    left join fee_stats      on landlords.landlord_id = fee_stats.landlord_id
    left join repair_stats   on landlords.landlord_id = repair_stats.landlord_id
)
select
    landlord_id,
    full_name,
    landlord_type,
    total_properties,
    occupancy_pct,
    fees_earned,
    repair_spend,
    net_value,
    rank() over (order by net_value desc) as value_rank,
    case when rank() over (order by net_value asc) <= 10
         then 'Bottom 10' else '' end as flag
from scorecard
order by value_rank;


/* #############################################################################
   OPTIONAL: EXPLORE THE TABLES (commented out so a full run returns only Q1-Q14)
   ############################################################################# */

-- show tables;
-- select * from branches;
-- select * from landlords;
-- select * from properties;
-- select * from tenants;
-- select * from tenancies;
-- select * from rent_payments;
-- select * from viewings;
-- select * from maintenance_requests;