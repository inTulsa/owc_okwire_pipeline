/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the AREA dimension by extracting the distinct list of counties
--                   (areas) referenced in job postings.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.POSTINGS.
-- COUNTY is aliased to AREAID and serves as the dimension's natural key; COUNTY_NAME is
-- carried through as the descriptive attribute.
-- Intended to be loaded into dim_area and joined to fact tables via AREAID.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT 
	COUNTY AS AREAID, 
	COUNTY_NAME 
FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS;