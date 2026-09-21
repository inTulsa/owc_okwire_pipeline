/*
---------------------------------------------------------------------------------------------------
--
-- Description: This SQL query retrieves the average yearly earnings for employees in an industry. 
--
-- Author:          Nile Dixon
-- Date:            2025-12-02
--
-- Notes: Lightcast does not return a single value for yearly or hourly wages. Rather, they report total earnings for all employees
    and the number of employees. Therefore, to find the average yearly earnings per employee, you must divide the 
    EARN value by the EMP value to get the average wages. 
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
    YEAR,
    AREAID,
    INDID,
    ROUND(EARN / EMP,2) AS YEARLY_WAGES
FROM 
    LIGHTCAST.TULSA_FOR_YOU.DAT_IND 
WHERE
    CLASSID = 1
    AND AREAID_TYPE = 'COUNTY'
    AND YEAR <= YEAR(CURRENT_DATE())