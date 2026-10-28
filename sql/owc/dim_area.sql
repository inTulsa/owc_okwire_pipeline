/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the AREA dimension by extracting the distinct list of counties
--                   (areas) referenced in job postings.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST_DATA.US.POSTINGS.
-- COUNTY is aliased to AREAID and serves as the dimension's natural key; COUNTY_NAME is
-- carried through as the descriptive attribute.
-- Intended to be loaded into dim_area and joined to fact tables via AREAID.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT 
	COUNTY AS AREAID, 
	COUNTY_NAME 
FROM LIGHTCAST_DATA.US.POSTINGS
WHERE LEFT(LPAD(COUNTY, 5, '0'), 2) = '40'
