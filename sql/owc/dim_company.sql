/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the COMPANY dimension by extracting the distinct list of companies
--                   referenced in job postings.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.POSTINGS.
-- COMPANY serves as the dimension's natural key; COMPANY_NAME is the descriptive attribute.
-- Intended to be loaded into dim_company and joined to fact tables via COMPANY.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT COMPANY, COMPANY_NAME FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS;