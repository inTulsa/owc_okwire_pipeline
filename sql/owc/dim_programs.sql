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
    PID.PROGRAMID AS PROGRAMID,
    PID.NAME AS NAME,
    PID3.PROGRAMID AS TLPROGRAMID,
    PID3.NAME AS TLNAME
FROM 
    LIGHTCAST.TULSA_FOR_YOU.DIM_PROGRAMID AS PID 
JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_PROGRAMID AS PID2
ON 
    PID.PROGRAMID_PARENT = PID2.PROGRAMID
JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_PROGRAMID AS PID3
ON 
    PID2.PROGRAMID_PARENT = PID3.PROGRAMID
WHERE 
    PID.LEVEL = 3