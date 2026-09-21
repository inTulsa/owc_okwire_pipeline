/*
---------------------------------------------------------------------------------------------------
--
-- Description: This SQL query retrieves the lowest level and highest level NAICS code from the 
	DIM_INDID table in lightcast.
--
-- Author:          Nile Dixon
-- Date:            2025-12-01
--
-- Notes: Because each row only contains a reference to the higher level and not the highest level,
	 a few self-joins were added. The t1.LEVEL = 6 clause ensures we get the lowest level NAICS code is 
	 retrieved as t1.
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
    t5.INDID AS TLINDID,
    t5.NAME AS NAICS2_NAME,
    t1.INDID AS INDID,
    t1.NAME AS NAICS6_NAME
FROM 
    LIGHTCAST.TULSA_FOR_YOU.DIM_INDID t1 
LEFT JOIN 
    LIGHTCAST.TULSA_FOR_YOU.DIM_INDID t2
ON
    t1.INDID_PARENT = t2.INDID
LEFT JOIN 
    LIGHTCAST.TULSA_FOR_YOU.DIM_INDID t3
ON
    t2.INDID_PARENT = t3.INDID
LEFT JOIN 
    LIGHTCAST.TULSA_FOR_YOU.DIM_INDID t4
ON
    t3.INDID_PARENT = t4.INDID
LEFT JOIN 
    LIGHTCAST.TULSA_FOR_YOU.DIM_INDID t5
ON
    t4.INDID_PARENT = t5.INDID
WHERE
    t1.LEVEL = 6