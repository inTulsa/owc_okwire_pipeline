/*
---------------------------------------------------------------------------------------------------
--
-- Description: This SQL query retrieves the lowest level and highest level SOC code from the 
	DIM_OCCID table in lightcast.
--
-- Author:          Nile Dixon
-- Date:            2025-12-01
--
-- Notes: The DIM_OCCID table only contains the information about the lowest level SOC code and none of the 
	intermdiary levels. However, the POSTINGS table contains the soc codes for each higher level. Therefore,
	I joined the SOC codes with the distinct list of the highest level socs present in the POSTINGS table.
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
WITH SOC_CODES AS (
    SELECT DISTINCT 
        CONCAT(LEFT(SOC_2, 2),'-0000') AS TL_SOC_CODE, 
        SOC_2_NAME 
    FROM 
        LIGHTCAST.TULSA_FOR_YOU.POSTINGS
)
SELECT 
    CONCAT(LEFT(OCCID, 2),'-0000') AS TLOCCID,
    SOC_CODES.SOC_2_NAME AS SOC_2_NAME,
    OCCID AS OCCID,
    NAME AS SOC_5_NAME,
    DESCRIPTION,
    TYPICALEDUCATION,
    TYPICALEXPERIENCE,
    TYPICALTRAINING
FROM
    LIGHTCAST.TULSA_FOR_YOU.DIM_OCCID AS DIMOCCID
RIGHT JOIN
    SOC_CODES
ON
    SOC_CODES.TL_SOC_CODE = CONCAT(LEFT(OCCID, 2),'-0000')
