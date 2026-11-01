# Teesside Lettings: SQL Analysis

Fourteen business questions for a Teesside letting agency, answered in MySQL. The project moves from joins and conditional aggregation to CTEs and window functions, and every result was reconciled against a source total to catch duplicated or dropped rows.

**Tools:** MySQL 8 · MySQL Workbench
**Author:** Anthony Ayumu

## Contents

- `teesside_lettings_mysql_setup.sql`: creates and populates the database
- `teesside_lettings_analysis.sql`: the 14 queries, each with its question, technique and assumptions

## The data

An agency with 4 branches managing 180 properties for 60 landlords. The database has 8 tables:

| Table | Rows | Description |
|---|---|---|
| `branches` | 4 | Agency branches |
| `landlords` | 60 | Landlord type and management fee % |
| `properties` | 180 | Type, bedrooms, EPC rating, listed rent, town |
| `tenants` | 420 | Employment status and referral source |
| `tenancies` | 317 | Start and end dates, status (Active, Ended, Terminated early) |
| `rent_payments` | | Amount due, amount paid, due and paid dates |
| `viewings` | | Viewing outcome (Applied, Not interested, No show) |
| `maintenance_requests` | 464 | Category, priority, dates, cost |

Key paths: `branches → properties → tenancies → rent_payments`, `landlords → properties → maintenance_requests`, `tenants → tenancies → rent_payments`.

## How to run

1. Run `teesside_lettings_mysql_setup.sql` to create the `teesside_lettings` database.
2. Run `teesside_lettings_analysis.sql`. Each query can also be run on its own.

## Questions and techniques

| # | Question | Techniques |
|---|---|---|
| 1 | Properties and average listed rent per branch | JOIN, COUNT, AVG |
| 2 | Average rent by property type and bedrooms | Multi-column GROUP BY |
| 3 | Referral sources that bring in signed tenants | COUNT(DISTINCT) |
| 4 | Current occupancy per branch | LEFT JOIN, conditional COUNT |
| 5 | Viewing-to-application conversion by property type | Conditional COUNT, rates |
| 6 | Management fees earned per landlord type | Four-table join, calculation inside SUM |
| 7 | Arrears report for Active tenancies | Conditional SUM, HAVING |
| 8 | Late payment rate by employment status | DATEDIFF, OR ... IS NULL |
| 9 | Repairs and spend per property by EPC rating | CTE, COALESCE, LAG, RANK |
| 10 | Monthly rent collected, running total, % change | Running SUM() OVER, LAG, NULLIF |
| 11 | Void periods by town | LAG with PARTITION BY |
| 12 | Top 3 costliest properties to maintain per branch | RANK with PARTITION BY |
| 13 | Maintenance SLA compliance by branch and priority | CTE, CASE |
| 14 | Landlord scorecard with ranking and bottom-10 flag | Multiple CTEs, RANK |

## Key findings

**Portfolio and pricing**
- Branches manage 72 (Middlesbrough Central), 51 (Stockton High Street), 31 (Redcar Seafront) and 26 (Hartlepool Marina) properties. Average listed rent runs from about £524 pcm in Hartlepool Marina to about £717 in Stockton High Street.
- Rent rises with bedrooms and property type, from about £367 for a room in an HMO to about £1,282 for a four-bed detached house.

**Occupancy and lettings**
- 156 of 180 properties (86.7%) have an Active tenancy. Hartlepool Marina is highest at 96.2% and Redcar Seafront lowest at 83.9%.
- Rightmove brings in the most signed tenants (73 of 213), followed by Zoopla (41). This measures volume, not conversion.
- Flats convert best from viewing to application (37.6% of attended viewings), and rooms in HMOs lowest (31.5%). About 1 in 6 booked viewings are no-shows (295 of 1,785).

**Revenue and collections**
- Management fees total about £182,222 to date: Portfolio £80,304, Company £79,099, Individual £22,819.
- Rent collected rose from about £85k in January 2025 to about £104k in August, then fell 11.3% in September. The data stops at September, so that last month is probably understated.
- 42 of 156 Active tenancies (27%) were behind on rent at 30 September 2025.
- Students (10.3%) and part-time workers (10.1%) have the highest late-payment rates, and retired tenants the lowest (4.6%). Universal Credit tenants (7.1%) are below the overall rate of about 8.2%.

**Maintenance and landlords**
- Repair spend per property rises at every step from EPC B (about £562) to F (about £2,830), and the number of requests rises with it. Ratings A and G contain a single property each, so this is an association on small groups, not proof of cause.
- Average void length is similar across towns (44 to 47 days), so no town stands out. Redcar (46.7) and Hartlepool (46.3) are highest, but each rests on only 19 voids.
- Only about 33% to 50% of maintenance jobs met their SLA target. Routine jobs did worst in the branches I checked (Middlesbrough Central, Stockton High Street, Redcar Seafront), which is surprising given the 28-day target. Open jobs count as misses, so the rates may be understated.
- The top of the landlord net-value ranking is dominated by Portfolio and Company landlords with 5 to 13 properties, so net value in pounds largely reflects portfolio size.

## Assumptions and limitations

- **As-of date:** arrears and late-payment queries use payments due up to 30 September 2025, the latest due date in the data.
- **Fees:** calculated on `amount_paid`, so unpaid rent earns nothing. All payments to date are included.
- **Late payment:** paid more than 3 days after the due date, or unpaid.
- **Viewing conversion:** no-shows are excluded from the denominator.
- **Repair spend:** open requests have no recorded cost, so they add nothing to spend.
- **SLA:** on time means days between reported and resolved date ≤ the target. Open jobs never count as on time.
- **Void periods:** only completed voids are counted, and town is the property's town.
- **Net value (Q14):** fees earned minus 15% of repair spend, as defined in the brief.
- **Small groups:** several results rest on small samples (EPC A and G, Emergency jobs per branch, towns with 19 voids). The queries return counts alongside rates for this reason.
- **Association, not cause:** EPC rating, property type and landlord size all travel together with other factors, so none of the patterns prove a cause.

## Skills shown

- Multi-table joins and choosing between inner and left joins
- Conditional aggregation with `CASE` and rate calculations
- CTEs, and window functions: `LAG`, `RANK`, running totals and `PARTITION BY`
- Avoiding fan-out when combining measures from different tables
- Reconciling every result against source totals and stating assumptions

## Related project

Power BI sales and operations dashboard: [add link]

## Next steps

Machine learning on the same data, for example predicting late payment or void length.
