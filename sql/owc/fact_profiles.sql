/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds a fact table counting candidate profiles by area, industry,
--                   occupation, and school attended.
--
-- Date:            2025-11-14
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.PROFILES and PROFILES_EDUCATIONS. Each dimension
-- (county, industry, occupation, school) is first reduced to its distinct ID-to-value
-- pairs before joining, so a profile with multiple values for one dimension can appear
-- in more than one combination.
--
---------------------------------------------------------------------------------------------------
*/

WITH PROFILE_EDUCATION_PAIRS AS (
    SELECT DISTINCT
        ID,
        SCHOOL_NAME
    FROM 
        LIGHTCAST.TULSA_FOR_YOU.PROFILES_EDUCATIONS
),
PROFILE_COUNTY_PAIRS AS (
    SELECT DISTINCT
        ID,
        COUNTY
    FROM
        LIGHTCAST.TULSA_FOR_YOU.PROFILES
),
PROFILE_IND_PAIRS AS (
    SELECT DISTINCT
        ID,
        NAICS6
    FROM
        LIGHTCAST.TULSA_FOR_YOU.PROFILES
),
PROFILE_OCC_PAIRS AS (
    SELECT DISTINCT
        ID,
        SOC_5
    FROM
        LIGHTCAST.TULSA_FOR_YOU.PROFILES
)
SELECT
    PROFILE_COUNTY_PAIRS.COUNTY AS AREAID,
    PROFILE_IND_PAIRS.NAICS6 AS INDID,
    PROFILE_OCC_PAIRS.SOC_5 AS OCCID,
    PROFILE_EDUCATION_PAIRS.SCHOOL_NAME AS SCHOOL,
    COUNT(*) AS TOTAL_PROFILES_COUNT
FROM
    PROFILE_EDUCATION_PAIRS
LEFT JOIN
    PROFILE_COUNTY_PAIRS
ON
    PROFILE_EDUCATION_PAIRS.ID = PROFILE_COUNTY_PAIRS.ID

LEFT JOIN
    PROFILE_IND_PAIRS
ON
    PROFILE_EDUCATION_PAIRS.ID = PROFILE_IND_PAIRS.ID
LEFT JOIN
    PROFILE_OCC_PAIRS
ON
    PROFILE_EDUCATION_PAIRS.ID = PROFILE_OCC_PAIRS.ID
GROUP BY
    AREAID,
    INDID,
    OCCID,
    SCHOOL
ORDER BY 
    TOTAL_PROFILES_COUNT DESC