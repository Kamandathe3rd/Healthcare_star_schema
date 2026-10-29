# Reflection: OLTP vs Star Schema
 
*Healthcare Analytics Lab, Part 4*
 
All numbers come from my own runs on the same PC and the same data
(10,003 patients, 100,004 encounters, ~600k rows in total), using the
median of 3 warm runs (see `docs/query_analysis.txt` and
`docs/star_schema_queries.txt`).
 
## 1. Why is the star schema faster?
 
**Joins: the count did not drop much, but what is joined changed.**
 
| Query | OLTP joins | Star joins | What changed |
|---|---|---|---|
| Q1 encounters by month/specialty | 2 | 3 | specialty is on the fact (no hop through providers); month comes from `dim_date` |
| Q2 diagnosis-procedure pairs | 3 | 3 | pairs counted on integer keys; codes looked up for 10 rows, not 373,894 |
| Q3 readmission rate | 3 (incl. self-join) | 2 | no self-join at all |
| Q4 revenue | 3 (billing -> encounters -> providers -> specialties) | 2 | billing not touched |
 
In OLTP every join walks through a large table (100k encounters, 90k
claims) or joins a large table to itself. In the star every join is one
hop from the fact to a small dimension (9 to 1,096 rows) on an integer
key. Most star plans showed "Covering index lookup", so the fact rows were
never read, only the indexes I designed for each question.
 
**Where data is pre-computed.** The ETL does the expensive work once:
 
- `readmitted_within_30d`: the Q3 self-join (15,074 stays x ~11 lookups)
  runs once per load and is stored as a 0/1 flag.
- `claim_count`, `total_claim_amount`, `total_allowed_amount`: billing is
  aggregated per encounter, so Q4 never reads the billing table.
- `diagnosis_count`, `procedure_count`, `length_of_stay_hours`.
- `dim_date.calendar_month`: the month label exists already, instead of
  running `DATE_FORMAT()` on every row (in Part 2 a function on the column
  made a one-month filter read ~100k rows instead of ~4k).
**Why denormalization helps analytics.** Normalization is built for
writing: each fact lives in one place, so updates are safe. Analytics does
the opposite: it reads many rows and groups them by attributes that 3NF
spreads over several tables. Copying `specialty_key` onto the fact and
the specialty/department names into `dim_provider` removes those hops.
Analytical queries read far more than they write, so paying once at load
time to save work on every query is a good deal.
 
## 2. Trade-offs: what did I gain and what did I lose?
 
**What I gave up**
 
- **Duplication and storage:** the star is a second copy of the data:
  71.8 MB next to the 79.1 MB OLTP database, and
  43.5 MB of it is indexes. Names are copied (specialty names in
  `dim_provider`), so a change must be updated in more than one place.
- **ETL complexity:** `06_etl_load.sql` has to respect load order, map
  natural keys to surrogate keys, handle missing data (Unknown key 0,
  `NO_AUTO_VALUE_ON_ZERO`), aggregate before joining, and be reconciled
  against OLTP after every run.
- **Freshness:** the star is only as current as the last load. With a
  nightly load, reports can be up to a day old, and late claims
  (1-14 days after discharge in my data) must be re-processed.
- **Some costs remain:** unique-patient counts (`COUNT(DISTINCT)`) cannot be
  pre-summed, and Q2's diagnosis x procedure explosion still exists.
**What I gained**
 
- **Speed:** 3.5x to 17.1x faster per query; all four together went from
  5.766 s to 0.923 s (6.2x).
- **Simpler, safer queries:** one hop per dimension, no self-join, and
  the per-encounter grain makes the double-counting trap from Part 2
  (revenue inflated from $299.7M to $748.6M) impossible.
- **One definition:** the 30-day readmission rule is written once in the
  ETL, so every report uses the same definition.
- **Same answers:** every star query returned exactly the same rows as
  its OLTP version, and the totals reconcile (100,004 encounters,
  $299,654,156.71, 880 readmissions).
**Was it worth it?** Yes, for analytics. Storage is cheap and the ETL is
written once, while the queries run every day. I would keep the OLTP
schema for the clinical system (fast, safe writes) and use the star
only for reporting, rather than replacing one with the other.
 
## 3. Bridge tables: worth it?
 
I kept diagnoses and procedures in `bridge_encounter_diagnoses` and
`bridge_encounter_procedures` instead of putting them in the fact
because:
 
- an encounter has 1-4 diagnoses and 0-3 procedures. Putting them in the
  fact would break the one-row-per-encounter grain and repeat the money
  on every row (the $748.6M problem);
- fixed columns such as `diagnosis_1 ... diagnosis_4` would cap the
  number of codes and make "find all encounters with code X" awkward.
**The trade-off:** Q2 still has to pair the two bridges, which creates
373,894 rows, so it improved the least (5.7x). The bridges made it
cheaper (narrow integer rows, primary keys starting with `encounter_key`
so each encounter's codes are stored together, and names looked up for
only 10 rows), but they did not remove the explosion.
 
**In production I would** keep the bridges, and also:
 
- add `primary_diagnosis_key` to the fact (from `diagnosis_sequence = 1`),
  so the most common analysis needs no bridge at all;
- if Q2 became a daily report, build a small pre-aggregated table of
  diagnosis-procedure pair counts during the ETL (300 rows), making it
  near-instant.
## 4. Performance quantification
 
| Query | OLTP | Star | Speed-up | Main reason |
|---|---|---|---|---|
| Q1 encounters by month/specialty | 0.438 s | 0.125 s | 3.5x | specialty on the fact, month from `dim_date`, covering index |
| Q2 diagnosis-procedure pairs | 3.812 s | 0.672 s | 5.7x | narrow bridges, late name lookups |
| **Q3 30-day readmission rate** | **0.547 s** | **0.032 s** | **17.1x** | **readmission flag pre-computed in the ETL** |
| **Q4 revenue by specialty & month** | **0.969 s** | **0.094 s** | **10.3x** | **revenue pre-aggregated on the fact** |
| All four combined | 5.766 s | 0.923 s | 6.2x | |
 
**Q3:** 0.547 s / 0.032 s = **17.1x faster**. The OLTP version scans all
100,004 encounters and runs a self-join for each of 15,074 inpatient
stays. The star version reads 15,074 rows from a covering index and sums
a 0/1 flag. (Workbench showed 0.016 s, one timer tick, so I used the
more conservative EXPLAIN ANALYZE time of 32 ms.)
 
**Q4:** 0.969 s / 0.094 s = **10.3x faster**. The OLTP version does
100,004 index lookups into billing through a 3-join chain. The star
version never touches billing because revenue is already stored per
encounter.
 
**Main lesson:** the biggest gains came from moving work into the ETL
(Q3, Q4), not just from removing joins. Where work cannot be done in
advance (unique counts in Q1, pairing in Q2), the gains were smaller.
 
**Limitations:** the data is synthetic and evenly spread (real codes and
specialties are more skewed). Orthopedics receives about twice the
non-ER visits because of how my generator re-assigns visits away from
Emergency doctors, and timings depend on my PC, so the ratios matter
more than the seconds.
.
 


