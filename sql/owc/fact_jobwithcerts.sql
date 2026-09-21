/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Nile Dixon
-- Date:            2025-11-14
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
    YEAR(P.POSTED) AS YEAR_POSTED,
    P.COUNTY AS AREAID,
    P.NAICS6 AS INDID,
    P.SOC_5 AS OCCID,
    P.COMPANY AS COMPANY,
    P.MIN_EDULEVELS AS MIN_EDULEVELS,
    P.IS_INTERNSHIP AS INTERNSHIP,
    COUNT(*) AS NUM_JOBS,
    (
        SELECT 
            COUNT(DISTINCT PS2.ID)
        FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS AS PS2
        LEFT JOIN LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P2
        ON PS2.ID = P2.ID
        WHERE
            PS2.SKILL_TYPE = 'Certification'
            AND PS2.SKILL_NAME <> 'Valid Driver\'s License'
            AND YEAR(P2.POSTED) = YEAR(P.POSTED)
            AND P2.COUNTY = P.COUNTY -- AREAID
            AND P2.NAICS6 = P.NAICS6 -- INDID
            AND P2.SOC_5 = P.SOC_5 -- OCCID
            AND P2.COMPANY = P.COMPANY -- COMPANY
            AND P2.MIN_EDULEVELS = P.MIN_EDULEVELS -- MIN_EDULEVELS
            AND P2.IS_INTERNSHIP = P.IS_INTERNSHIP -- INTERNSHIP
    ) AS NUM_JOBS_WITH_CERT
FROM
LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
GROUP BY
    YEAR_POSTED,
    AREAID,
    INDID,
    OCCID,
    COMPANY,
    MIN_EDULEVELS,
    INTERNSHIP
ORDER BY
    NUM_JOBS_WITH_CERT DESC