/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the SKILLS dimension by extracting the distinct skills referenced
--                   in job postings, along with their category and subcategory classification.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST_DATA.US.POSTINGS_SKILLS.
-- SKILL_ID is the dimension's natural key. SKILL_CATEGORY/SKILL_SUBCATEGORY group skills into
-- a taxonomy; IS_SOFTWARE flags skills that represent specific software tools.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT 
	SKILL_ID, 
	SKILL_NAME, 
	SKILL_TYPE, 
	SKILL_CATEGORY, 
	SKILL_CATEGORY_NAME,
	SKILL_SUBCATEGORY, 
	SKILL_SUBCATEGORY_NAME,
	IS_SOFTWARE
FROM LIGHTCAST_DATA.US.POSTINGS_SKILLS
WHERE ID IN (SELECT ID FROM LIGHTCAST_DATA.US.POSTINGS WHERE LEFT(LPAD(COUNTY, 5, '0'), 2) = '40')
