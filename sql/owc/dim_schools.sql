/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the SCHOOLS dimension from the master list of postsecondary
--                   institutions, including location and sector classification.
--
-- Date:            2025-11-05
--
-- Notes:
-- Source: LIGHTCAST_DATA.CORELMI_US_V3.DIM_UNITID.
-- UNITID is the institution's natural key; COUNTY is aliased to AREAID so it can be joined
-- to dim_area. SECTOR/SECTOR_DESCRIPTION classify the institution type (e.g. public, private,
-- for-profit).
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
	UNITID, 
	COUNTY AS AREAID,
	NAME,
	SECTOR,
	SECTOR_DESCRIPTION
FROM 
	LIGHTCAST_DATA.CORELMI_US_V3.DIM_UNITID
WHERE
	LEFT(LPAD(COUNTY, 5, '0'), 2) = '40'
