/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Nile Dixon
-- Date:            2025-11-05
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
WITH PCTS AS (
    SELECT
        DS.YEAR + 1 AS YEAR,
        DS.AREAID,
        DS.INDID,
        DS.OCCID,
        DS.PERCENT
    FROM LIGHTCAST.TULSA_FOR_YOU.DAT_STAFFING AS DS 
    WHERE
        DS.CLASSID = '1'
        AND DS.AREAID_TYPE = 'COUNTY'
        AND DS.YEAR <= YEAR(CURRENT_DATE())
),
HAS AS (
    SELECT 
        YEAR + 1 AS YEAR, 
        AREAID, 
        INDID, 
        SUM(HIRA) AS HIRES, 
        SUM(SEP) AS SEPS 
    FROM LIGHTCAST.TULSA_FOR_YOU.DAT_IND_RACE_ETHN_HIRESSEPS 
    WHERE 
        AREAID_TYPE = 'COUNTY' 
        AND YEAR <= YEAR(CURRENT_DATE()) 
    GROUP BY 
        YEAR, 
        AREAID, 
        INDID
)
SELECT 
    PCTS.YEAR,
    PCTS.AREAID,
    PCTS.INDID,
    PCTS.OCCID,
    PCTS.PERCENT,
    HAS.HIRES AS HIRES,
    HAS.HIRES * PCTS.PERCENT AS OCC_HIRES,
    HAS.SEPS AS SEPS,
    HAS.SEPS * PCTS.PERCENT AS OCC_SEPS
FROM PCTS
LEFT JOIN HAS ON
    PCTS.YEAR = HAS.YEAR
    AND PCTS.AREAID = HAS.AREAID
    AND PCTS.INDID = HAS.INDID