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
	UNITID, 
	COUNTY AS AREAID,
	NAME,
	SECTOR,
	SECTOR_DESCRIPTION
FROM 
	LIGHTCAST.TULSA_FOR_YOU.DIM_UNITID;