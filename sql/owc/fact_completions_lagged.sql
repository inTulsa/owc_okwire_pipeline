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
	CD.YEAR + 1 AS YEAR,
    DIM_UID.COUNTY AS AREAID,
	CD.PROGRAMID AS PROGRAMID,
	CD.UNITID AS UNITID,
    CD.AWLEVELID AS AWLEVELID,
    CD.COMPLETIONS AS COMPLETIONS
FROM 
	LIGHTCAST.TULSA_FOR_YOU.DAT_COMPLETIONS_DEMOGRAPHICS AS CD 
LEFT JOIN 
	LIGHTCAST.TULSA_FOR_YOU.DIM_PROGRAMID AS DIM_PID 
ON 
	CD.PROGRAMID = DIM_PID.PROGRAMID
LEFT JOIN 
	LIGHTCAST.TULSA_FOR_YOU.DIM_UNITID AS DIM_UID
ON
	CD.UNITID = DIM_UID.UNITID
WHERE 
	DIM_PID.LEVEL = 3
	AND (
        CD.AWLEVELID = 3 
        OR CD.AWLEVELID = 5 
        OR CD.AWLEVELID = 7 
        OR CD.AWLEVELID = 9 
        OR CD.AWLEVELID = 11
    )
	AND RACEID = 0
	AND GENDERID = 0;