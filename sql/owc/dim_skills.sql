/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Nile Dixon
-- Date:            2025-10-29
--
-- Notes:
-- 
--
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