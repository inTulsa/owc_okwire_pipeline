/*
---------------------------------------------------------------------------------------------------
--
-- Description: This table obtains the average hourly salary 
--
-- Author:          Nile Dixon
-- Date:            2025-12-02
--
-- Notes: To simplify the query, I just obtained the hourly wages for individuals with a classid of 1 (QCEW Employees).
    If you want to include all types of employees when retrieving the average hourly salary, you need to do a weighted average 
    based on the EMP and EARN_AVG columns.
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
SELECT
    YEAR,
    AREAID,
    OCCID,
    ROUND(EARN_AVG,2) AS HOURLY_WAGE,
    ROUND(EARN_AVG,2) * 2080 AS YEARLY_WAGE
FROM
    LIGHTCAST.TULSA_FOR_YOU.DAT_OCC
WHERE
    CLASSID = 1
    AND AREAID_TYPE = 'COUNTY'
    AND YEAR <= YEAR(CURRENT_DATE()) 