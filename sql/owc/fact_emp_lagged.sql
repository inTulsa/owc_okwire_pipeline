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
EMP AS (
    SELECT
        DAT_IND.YEAR + 1 AS YEAR,
        DAT_IND.AREAID,
        DAT_IND.INDID,
        SUM(EMP) AS NUM_EMPS
    FROM
        LIGHTCAST.TULSA_FOR_YOU.DAT_IND
    LEFT JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_INDID
    ON
        DAT_IND.INDID = DIM_INDID.INDID
    WHERE
        AREAID_TYPE = 'COUNTY'
        AND YEAR <= YEAR(CURRENT_DATE())
        AND DAT_IND.CLASSID <> '4'
    GROUP BY
        DAT_IND.YEAR,
        DAT_IND.AREAID,
        DAT_IND.INDID  
)
SELECT 
    PCTS.YEAR,
    PCTS.AREAID,
    PCTS.INDID,
    PCTS.OCCID,
    PCTS.PERCENT,
    EMP.NUM_EMPS AS NUM_EMPS,
    EMP.NUM_EMPS * PCTS.PERCENT AS OCC_EMPS
FROM PCTS
LEFT JOIN EMP ON
    PCTS.YEAR = EMP.YEAR
    AND PCTS.AREAID = EMP.AREAID
    AND PCTS.INDID = EMP.INDID