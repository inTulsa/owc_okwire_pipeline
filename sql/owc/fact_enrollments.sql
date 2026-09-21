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