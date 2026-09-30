/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the SKILLS dimension by extracting the distinct skills referenced
--                   in job postings, along with their category and subcategory classification.
--
-- Date:            2025-10-29
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS.
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
FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS;