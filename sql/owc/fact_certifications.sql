/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the certifications fact table: counts of job postings that list
--                   each certification skill, by year, area, industry, occupation, company,
--                   minimum education, and internship flag.
--
-- Date:            2025-11-14
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS left joined to POSTINGS. Filtered to
-- SKILL_TYPE = 'Certification', excluding "Valid Driver's License" (which Lightcast tags
-- as a certification but isn't one).
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
    COUNT(*) AS TOTAL_CERTS_COUNT
FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS AS PS
LEFT JOIN LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
ON
    PS.ID = P.ID
WHERE 
    SKILL_TYPE = 'Certification'
    AND SKILL_NAME <> 'Valid Driver''s License'
GROUP BY 
    YEAR_POSTED,
    AREAID,
    INDID,
    OCCID,
    COMPANY,
    MIN_EDULEVELS,
    INTERNSHIP,
    SKILL_ID 