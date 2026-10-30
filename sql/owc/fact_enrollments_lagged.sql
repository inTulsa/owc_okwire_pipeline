/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Lagged (prior-year) counterpart to fact_enrollments, used for year-over-year
--                   comparisons.
--
-- Date:            2025-11-05
--
-- Notes:
-- Identical to fact_enrollments, except YEAR is shifted forward by 1 (YEAR + 1) so each row
-- lines up with the following year's fact_enrollments row when joined on YEAR/AREAID/etc.
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
	EN.YEAR + 1 AS YEAR,
    DIM_UID.COUNTY AS AREAID,
    DIM_UID.UNITID AS UNITID,
    EN.ENROLLMENTS AS ENROLLMENTS
FROM 
	LIGHTCAST_DATA.CORELMI_US_V3.DAT_ENROLLMENTS AS EN
LEFT JOIN 
	LIGHTCAST_DATA.CORELMI_US_V3.DIM_UNITID AS DIM_UID
ON
	EN.UNITID = DIM_UID.UNITID
WHERE
	LEFT(LPAD(DIM_UID.COUNTY, 5, '0'), 2) = '40'
	AND EN.RACEID = 0
	AND EN.GENDERID = 0
	AND EN.ENRLEVELID = 1
