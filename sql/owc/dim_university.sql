/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the UNIVERSITY dimension from the master list of postsecondary
--                   institutions, with each institution's county name resolved for reporting.
--
-- Date:            2026-07-10
--
-- Notes:
-- Source: DIM_UNITID, left joined to REF_AREAID on COUNTY = AREAID to resolve COUNTYNM.
-- Institutions flagged as "not current" (closed/inactive) are excluded.
-- Field names (INSTNM, ADDR, STABBR, LONGITUD, LATITUDE) follow IPEDS naming conventions.
--
---------------------------------------------------------------------------------------------------
*/

SELECT DISTINCT 
    DU.UNITID,
    DU.NAME as INSTNM,
    DU.ADDRESS as ADDR,
    DU.CITY,
    DU.STATEABBREVIATION as STABBR,
    DU.ZIP,
    DU.COUNTY AS COUNTYCD,
    RA.AREAID_NAME AS COUNTYNM,
    DU.LONGITUDE as LONGITUD,
    DU.LATITUDE as LATITUDE    
FROM DIM_UNITID DU
LEFT JOIN REF_AREAID RA
ON DU.COUNTY = RA.AREAID
WHERE NAME NOT LIKE '%not current%'