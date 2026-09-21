/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Steven Vang
-- Date:            2026-07-10
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/

SELECT DISTINCT 
    UNITID,
    NAME as INSTNM,
    ADDRESS as ADDR,
    CITY,
    STATEABBREVIATION as STABBR,
    ZIP,
    COUNTY AS COUNTYCD,
    LONGITUDE as LONGITUD,
    LATITUDE as LATITUDE    
FROM DIM_UNITID
WHERE NAME NOT LIKE '%not current%'