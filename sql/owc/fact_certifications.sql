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
    PS.SKILL_ID AS SKILL_ID,
    COUNT(*) 
FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS AS PS
LEFT JOIN LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
ON
    PS.ID = P.ID
WHERE 
    SKILL_TYPE = 'Certification'
    AND SKILL_NAME <> 'Valid Driver\'s License'
GROUP BY 
    YEAR_POSTED,
    AREAID,
    INDID,
    OCCID,
    COMPANY,
    MIN_EDULEVELS,
    INTERNSHIP,
    SKILL_ID 