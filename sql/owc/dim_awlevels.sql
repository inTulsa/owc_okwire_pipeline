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
SELECT DISTINCT 
    AWLEVELID, 
    AWLEVELID_NAME 
FROM LIGHTCAST.TULSA_FOR_YOU.DAT_COMPLETIONS_DEMOGRAPHICS AS CD 
WHERE (
    CD.AWLEVELID = 3 
    OR CD.AWLEVELID = 5 
    OR CD.AWLEVELID = 7 
    OR CD.AWLEVELID = 9 
    OR CD.AWLEVELID = 11
)