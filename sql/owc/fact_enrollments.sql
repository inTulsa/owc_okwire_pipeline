/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the enrollments fact table: total enrollments by year, area, and
--                   institution.
--
-- Date:            2025-11-05
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DAT_ENROLLMENTS, left joined to DIM_UNITID (for AREAID).
-- Filtered to RACEID = 0 / GENDERID = 0 (all-race, all-gender totals) and ENRLEVELID = 1,
-- to avoid double counting demographic and enrollment-level breakouts.
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
	EN.YEAR AS YEAR,
    DIM_UID.COUNTY AS AREAID,
    DIM_UID.UNITID AS UNITID,
    EN.ENROLLMENTS AS ENROLLMENTS
FROM 
	LIGHTCAST.TULSA_FOR_YOU.DAT_ENROLLMENTS AS EN
LEFT JOIN 
	LIGHTCAST.TULSA_FOR_YOU.DIM_UNITID AS DIM_UID
ON
	EN.UNITID = DIM_UID.UNITID
WHERE
	EN.RACEID = 0
	AND EN.GENDERID = 0
	AND EN.ENRLEVELID = 1