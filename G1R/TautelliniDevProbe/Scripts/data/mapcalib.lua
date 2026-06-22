-- Baked map calibration: the affine transform from normalized cursor (cursor / viewport
-- size) to world XY, captured once in-game via the map probe and pasted here so it ships
-- and loads with NO in-game calibration. nil until a good spread fit exists.
--
-- Shape when set:
--   return { M = { ax=, bx=, cx=, ay=, by=, cy= }, pts = { { nx=, ny=, wx=, wy= }, ... } }
-- world = (ax*nx + bx*ny + cx, ay*nx + by*ny + cy)
return nil
