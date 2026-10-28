/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the minimum-education-level (MIN_EDULEVELS) dimension by extracting
--                   the distinct minimum education requirements referenced in job postings.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST_DATA.US.POSTINGS.
-- MIN_EDULEVELS is the dimension's natural key; MIN_EDULEVELS_NAME is the descriptive label.
-- Intended to be loaded into dim_edulevels and joined to fact tables via MIN_EDULEVELS.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT MIN_EDULEVELS, MIN_EDULEVELS_NAME FROM LIGHTCAST_DATA.US.POSTINGS
WHERE LEFT(LPAD(COUNTY, 5, '0'), 2) = '40'
