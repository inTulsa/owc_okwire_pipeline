/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the occupation (OCC) dimension, pairing each detailed SOC occupation
--                   from DIM_OCCID with its top-level (2-digit) SOC group.
--
-- Date:            2025-12-01
--
-- Notes:
-- DIM_OCCID only contains detailed (lowest-level) SOC codes with no intermediary levels, while
-- POSTINGS contains the top-level SOC codes and names. The top-level SOC codes derived from
-- POSTINGS are joined back to DIM_OCCID (matching on the first 2 digits) to attach the
-- top-level grouping to each detailed occupation record.
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
