/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Nile Dixon
-- Date:            2025-10-29
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
WITH TJ AS (
    SELECT
        YEAR(POSTED) AS YEAR_POSTED,
        COUNTY AS AREAID,
        NAICS6 AS INDID,
        SOC_5 AS OCCID,
        MIN_EDULEVELS,
        IS_INTERNSHIP,
        COUNT(ID) AS TOTAL_JOBS_COUNT
    FROM
        LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P_TOTAL
    GROUP BY
        YEAR_POSTED,
        AREAID,
        INDID,
        OCCID,
        MIN_EDULEVELS,
        IS_INTERNSHIP
)
SELECT
    PS.SKILL_ID,
    YEAR(P.POSTED) AS YEAR_POSTED,
    P.COUNTY AS AREAID,
    P.NAICS6 AS INDID,
    P.SOC_5 AS OCCID,
    P.MIN_EDULEVELS,
    P.IS_INTERNSHIP,
    COUNT(*) AS CURR_NUM_SKILLS,
    T.TOTAL_JOBS_COUNT AS CURR_TOTAL_JOBS_COUNT
FROM
    LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS AS PS
JOIN
    LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
    ON PS.ID = P.ID
JOIN
    TJ AS T
    ON YEAR(P.POSTED) = T.YEAR_POSTED
    AND P.COUNTY = T.AREAID
    AND P.NAICS6 = T.INDID
    AND P.SOC_5 = T.OCCID
    AND P.MIN_EDULEVELS = T.MIN_EDULEVELS
    AND P.IS_INTERNSHIP = T.IS_INTERNSHIP
WHERE
    P.COMPANY_IS_STAFFING = FALSE
GROUP BY
    PS.SKILL_ID,
    YEAR(P.POSTED),
    P.COUNTY,
    P.NAICS6,
    P.SOC_5,
    P.MIN_EDULEVELS,
    P.IS_INTERNSHIP,
    T.TOTAL_JOBS_COUNT