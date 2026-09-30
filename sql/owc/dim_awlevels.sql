/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the award-level (AWLEVELID) dimension, limited to the postsecondary
--                   award levels used for completions reporting (Associate's through Doctoral).
--
-- Date:            2025-11-05
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DAT_COMPLETIONS_DEMOGRAPHICS.
-- Only AWLEVELID values 3, 5, 7, 9, and 11 are included (Associate's, Bachelor's, Master's,
-- and Doctoral award levels); sub-associate and certificate-level awards are excluded.
-- Intended to be loaded into dim_awlevels and joined to completions facts via AWLEVELID.
--
---------------------------------------------------------------------------------------------------
*/
SELECT DISTINCT 
    AWLEVELID, 
    AWLEVELID_NAME 
FROM LIGHTCAST.TULSA_FOR_YOU.DAT_COMPLETIONS_DEMOGRAPHICS AS CD 
WHERE (
    CD.AWLEVELID = 3 
    OR CD.AWLEVELID = 5 
    OR CD.AWLEVELID = 7 
    OR CD.AWLEVELID = 9 
    OR CD.AWLEVELID = 11
)