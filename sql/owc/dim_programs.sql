/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the education program (PROGRAMID) dimension, pairing each detailed
--                   (level 3) program from DIM_PROGRAMID with its top-level (level 1) program
--                   grouping.
--
-- Date:            2025-11-05
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DIM_PROGRAMID, self-joined twice via PROGRAMID_PARENT to
-- walk up the program hierarchy from level 3 to level 1.
-- PROGRAMID/NAME identify the detailed (level 3) program; TLPROGRAMID/TLNAME identify its
-- top-level (level 1) parent grouping.
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