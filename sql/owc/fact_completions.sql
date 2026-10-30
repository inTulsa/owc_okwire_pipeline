/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the completions fact table: total postsecondary completions for the
--                   current year by area, program, institution, and award level.
--
-- Date:            2025-11-05
--
-- Notes:
-- Source: LIGHTCAST_DATA.CORELMI_US_V3.DAT_COMPLETIONS_DEMOGRAPHICS, left joined to DIM_PROGRAMID
-- (filtered to LEVEL = 3, the detailed program level) and DIM_UNITID (for AREAID).
-- Filtered to AWLEVELID 3, 5, 7, 9, 11 (Associate's through Doctoral) and to RACEID = 0 /
-- GENDERID = 0 (all-race, all-gender totals) to avoid double counting demographic breakouts.
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
	CD.YEAR AS YEAR,
    DIM_UID.COUNTY AS AREAID,
	CD.PROGRAMID AS PROGRAMID,
	CD.UNITID AS UNITID,
    CD.AWLEVELID AS AWLEVELID,
    CD.COMPLETIONS AS COMPLETIONS
FROM 
	LIGHTCAST_DATA.CORELMI_US_V3.DAT_COMPLETIONS_DEMOGRAPHICS AS CD 
LEFT JOIN 
	LIGHTCAST_DATA.CORELMI_US_V3.DIM_PROGRAMID AS DIM_PID 
ON 
	CD.PROGRAMID = DIM_PID.PROGRAMID
LEFT JOIN 
	LIGHTCAST_DATA.CORELMI_US_V3.DIM_UNITID AS DIM_UID
ON
	CD.UNITID = DIM_UID.UNITID
WHERE 
	LEFT(LPAD(DIM_UID.COUNTY, 5, '0'), 2) = '40'
	AND DIM_PID.LEVEL = 3
	AND (
        CD.AWLEVELID = 3 
        OR CD.AWLEVELID = 5 
        OR CD.AWLEVELID = 7 
        OR CD.AWLEVELID = 9 
        OR CD.AWLEVELID = 11
    )
	AND RACEID = 0
	AND GENDERID = 0
