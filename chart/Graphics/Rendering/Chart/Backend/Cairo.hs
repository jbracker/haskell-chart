
-- | The backend to render charts with cairo.
module Graphics.Rendering.Chart.Backend.Cairo
  ( convertLineCap, convertLineJoin
  , convertFontSlant, convertFontWeight
  
  , preserveCState

  , setSourceColor
  
  , setClipRegion
  , moveTo
  , lineTo
  , strokePath
  , fillPath
    
  , alignp
  , alignc
  , drawText
  , drawTextR
  , drawTextsR
  , textSize
  , textDrawRect
  
  , setLineStyle
  , setFillStyle
  , setFontStyle
    
  , cTranslate
  , cRotate
  , cNewPath
  , cMoveTo
  , cLineTo
  , cRelLineTo
  , cArc
  , cArcNegative
  , cClosePath
  , cStroke
  , cFill
  , cFillPreserve
  , cSetSourceColor
  , cPaint
  , cFontExtents
  , cFontExtentsDescent
  , cShowText

  , cRenderToPNGFile
  , cRenderToPSFile
  , cRenderToPDFFile
  , cRenderToSVGFile
  , vectorEnv
  , bitmapEnv
  ) where

import Data.Colour
import Data.Colour.SRGB
import Data.List (unfoldr)

import Control.Monad.Reader

import qualified Graphics.Rendering.Cairo as C

import qualified Graphics.Rendering.Chart.Types as G
import Graphics.Rendering.Chart.Types 
  ( c
  , runCRender
  , CRender, CEnv(..)
  , PointShape(..)
  , FillStyle(..), PointStyle(..), FontStyle(..), LineStyle(..)
  , HTextAnchor(..), VTextAnchor(..)
  )
import Graphics.Rendering.Chart.Geometry

-- -----------------------------------------------------------------------
-- Type Conversions: Chart -> Cairo
-- -----------------------------------------------------------------------

-- | Convert a charts line join to a cairo line join.
convertLineJoin :: G.LineJoin -> C.LineJoin
convertLineJoin lj = case lj of
  G.LineJoinMiter -> C.LineJoinMiter
  G.LineJoinRound -> C.LineJoinRound
  G.LineJoinBevel -> C.LineJoinBevel

-- | Convert a charts line cap to a cairo line cap.
convertLineCap :: G.LineCap -> C.LineCap
convertLineCap lc = case lc of
  G.LineCapRound  -> C.LineCapRound
  G.LineCapButt   -> C.LineCapButt
  G.LineCapSquare -> C.LineCapSquare

convertFontSlant :: G.FontSlant -> C.FontSlant
convertFontSlant fs = case fs of
  G.FontSlantItalic  -> C.FontSlantItalic
  G.FontSlantNormal  -> C.FontSlantNormal
  G.FontSlantOblique -> C.FontSlantOblique

convertFontWeight :: G.FontWeight -> C.FontWeight
convertFontWeight fw = case fw of
  G.FontWeightBold   -> C.FontWeightBold
  G.FontWeightNormal -> C.FontWeightNormal

-- -----------------------------------------------------------------------
-- Assorted helper functions in Cairo Usage
-- -----------------------------------------------------------------------

alignp :: Point -> CRender Point
alignp p = do 
    alignfn <- fmap cenv_point_alignfn ask
    return (alignfn p)

alignc :: Point -> CRender Point
alignc p = do 
    alignfn <- fmap cenv_coord_alignfn ask
    return (alignfn p)

-- | Function to draw a textual label anchored by one of its corners
--   or edges.
drawText :: HTextAnchor -> VTextAnchor -> Point -> String -> CRender ()
drawText hta vta p s = drawTextR hta vta 0 p s

moveTo, lineTo :: Point -> CRender ()
moveTo p  = do
    p' <- alignp p
    c $ C.moveTo (p_x p') (p_y p')

lineTo p = do
    p' <- alignp p
    c $ C.lineTo (p_x p') (p_y p')

setClipRegion :: Point -> Point -> CRender ()
setClipRegion p2 p3 = do    
    c $ C.moveTo (p_x p2) (p_y p2)
    c $ C.lineTo (p_x p2) (p_y p3)
    c $ C.lineTo (p_x p3) (p_y p3)
    c $ C.lineTo (p_x p3) (p_y p2)
    c $ C.lineTo (p_x p2) (p_y p2)
    c $ C.clip

stepPath :: [Point] -> CRender()
stepPath (p:ps) = c $ do
    C.newPath                    
    C.moveTo (p_x p) (p_y p)
    mapM_ (\p -> C.lineTo (p_x p) (p_y p)) ps
stepPath _  = return ()

-- | Draw lines between the specified points.
--
-- The points will be "corrected" by the cenv_point_alignfn, so that
-- when drawing bitmaps, 1 pixel wide lines will be centred on the
-- pixels.
strokePath :: [Point] -> CRender()
strokePath pts = do
    alignfn <- fmap cenv_point_alignfn ask
    stepPath (map alignfn pts)
    c $ C.stroke

-- | Fill the region with the given corners.
--
-- The points will be "corrected" by the cenv_coord_alignfn, so that
-- when drawing bitmaps, the edges of the region will fall between
-- pixels.
fillPath ::  [Point] -> CRender()
fillPath pts = do
    alignfn <- fmap cenv_coord_alignfn ask
    stepPath (map alignfn pts)
    c $ C.fill

setFontStyle :: FontStyle -> CRender ()
setFontStyle f = do
    c $ C.selectFontFace (G.font_name_ f) 
                         (convertFontSlant $ G.font_slant_ f) 
                         (convertFontWeight $ G.font_weight_ f)
    c $ C.setFontSize (G.font_size_ f)
    c $ setSourceColor (G.font_color_ f)

setLineStyle :: LineStyle -> CRender ()
setLineStyle ls = do
    c $ C.setLineWidth (G.line_width_ ls)
    c $ setSourceColor (G.line_color_ ls)
    c $ C.setLineCap (convertLineCap $ G.line_cap_ ls)
    c $ C.setLineJoin (convertLineJoin $ G.line_join_ ls)
    c $ C.setDash (G.line_dashes_ ls) 0

setFillStyle :: FillStyle -> CRender ()
setFillStyle (FillStyleSolid cl) = do
  c $ setSourceColor cl

colourChannel :: (Floating a, Ord a) => AlphaColour a -> Colour a
colourChannel c = darken (recip (alphaChannel c)) (c `over` black)

setSourceColor :: AlphaColour Double -> C.Render ()
setSourceColor c = let (RGB r g b) = toSRGB $ colourChannel c
                   in C.setSourceRGBA r g b (alphaChannel c)

-- | Return the bounding rectangle for a text string rendered
--   in the current context.
textSize :: String -> CRender RectSize
textSize s = c $ do
    te <- C.textExtents s
    fe <- C.fontExtents
    return (C.textExtentsWidth te, C.fontExtentsHeight fe)

-- | Recturn the bounding rectangle for a text string positioned
--   where it would be drawn by drawText
textDrawRect :: HTextAnchor -> VTextAnchor -> Point -> String -> CRender Rect
textDrawRect hta vta (Point x y) s = preserveCState $ textSize s >>= rect
    where
      rect (w,h) = c $ do te <- C.textExtents s
                          fe <- C.fontExtents
                          let lx = xadj hta (C.textExtentsWidth te)
                          let ly = yadj vta te fe
                          let (x',y') = (x + lx, y + ly)
                          let p1 = Point x' y'
                          let p2 = Point (x' + w) (y' + h)
                          return $ Rect p1 p2

      xadj HTA_Left   w = 0
      xadj HTA_Centre w = (-w/2)
      xadj HTA_Right  w = (-w)
      yadj VTA_Top      te fe = C.fontExtentsAscent fe
      yadj VTA_Centre   te fe = - (C.textExtentsYbearing te) / 2
      yadj VTA_BaseLine te fe = 0
      yadj VTA_Bottom   te fe = -(C.fontExtentsDescent fe)

-- | Function to draw a textual label anchored by one of its corners
--   or edges, with rotation. Rotation angle is given in degrees,
--   rotation is performed around anchor point.
drawTextR :: HTextAnchor -> VTextAnchor -> Double -> Point -> String -> CRender ()
drawTextR hta vta angle (Point x y) s = preserveCState $ draw
    where
      draw =  c $ do te <- C.textExtents s
                     fe <- C.fontExtents
                     let lx = xadj hta (C.textExtentsWidth te)
                     let ly = yadj vta te fe
                     C.translate x y
                     C.rotate theta
                     C.moveTo lx ly
                     C.showText s
      theta = angle*pi/180.0
      xadj HTA_Left   w = 0
      xadj HTA_Centre w = (-w/2)
      xadj HTA_Right  w = (-w)
      yadj VTA_Top      te fe = C.fontExtentsAscent fe
      yadj VTA_Centre   te fe = - (C.textExtentsYbearing te) / 2
      yadj VTA_BaseLine te fe = 0
      yadj VTA_Bottom   te fe = -(C.fontExtentsDescent fe)

-- | Function to draw a multi-line textual label anchored by one of its corners
--   or edges, with rotation. Rotation angle is given in degrees,
--   rotation is performed around anchor point.
drawTextsR :: HTextAnchor -> VTextAnchor -> Double -> Point -> String -> CRender ()
drawTextsR hta vta angle (Point x y) s = preserveCState $ drawAll
    where
      ss   = lines s
      num  = length ss
      drawAll =  c $ do tes <- mapM C.textExtents ss
                        fe  <- C.fontExtents
                        let widths = map C.textExtentsWidth tes
                            maxw   = maximum widths
                            maxh   = maximum (map C.textExtentsYbearing tes)
                            gap    = maxh / 2 -- half-line spacing
                            totalHeight = fromIntegral num*maxh +
                                          (fromIntegral num-1)*gap
                            ys = take num (unfoldr (\y-> Just (y, y-gap-maxh))
                                                   (yinit vta fe totalHeight))
                            xs = map (xadj hta) widths
                        C.translate x y
                        C.rotate theta
                        sequence_ (zipWith3 draw xs ys ss)

      draw lx ly s =  do C.moveTo lx ly
                         C.showText s
      theta = angle*pi/180.0

      xadj HTA_Left   w = 0
      xadj HTA_Centre w = (-w/2)
      xadj HTA_Right  w = (-w)

      yinit VTA_Top      fe height = C.fontExtentsAscent fe
      yinit VTA_BaseLine fe height = 0
      yinit VTA_Centre   fe height = height / 2 + C.fontExtentsAscent fe
      yinit VTA_Bottom   fe height = height + C.fontExtentsAscent fe


-- | Execute a rendering action in a saved context (ie bracketed
--   between C.save and C.restore).
preserveCState :: CRender a -> CRender a
preserveCState a = do 
  c $ C.save
  v <- a
  c $ C.restore
  return v

-- -----------------------------------------------------------------------

drawPoint :: PointStyle -> Point -> CRender ()
drawPoint (PointStyle cl bcl bw r shape) p = do
  (Point x y) <- alignp p
  case shape of
    PointShapeCircle -> do
      c $ setSourceColor cl
      c $ C.newPath
      c $ C.arc x y r 0 (2*pi)
      c $ C.fill
    PointShapePolygon sides isrot -> do
      c $ setSourceColor cl
      c $ C.newPath
      let intToAngle n =
            if isrot
            then       fromIntegral n * 2*pi/fromIntegral sides
            else (0.5 + fromIntegral n)*2*pi/fromIntegral sides
          angles = map intToAngle [0 .. sides-1]
          (p:ps) = map (\a -> Point (x + r * sin a)
                                    (y + r * cos a)) angles
      moveTo p
      mapM_ lineTo (ps++[p])
      c $ C.fill
    PointShapePlus -> do
      c $ C.newPath
      c $ C.moveTo (x+r) y
      c $ C.lineTo (x-r) y
      c $ C.moveTo x (y-r)
      c $ C.lineTo x (y+r)
    PointShapeCross -> do
      let rad = r / sqrt 2
      c $ C.newPath
      c $ C.moveTo (x+rad) (y+rad)
      c $ C.lineTo (x-rad) (y-rad)
      c $ C.moveTo (x+rad) (y-rad)
      c $ C.lineTo (x-rad) (y+rad)
    PointShapeStar -> do
      let rad = r / sqrt 2
      c $ C.newPath
      c $ C.moveTo (x+r) y
      c $ C.lineTo (x-r) y
      c $ C.moveTo x (y-r)
      c $ C.lineTo x (y+r)
      c $ C.moveTo (x+rad) (y+rad)
      c $ C.lineTo (x-rad) (y-rad)
      c $ C.moveTo (x+rad) (y-rad)
      c $ C.lineTo (x-rad) (y+rad)
  c $ C.setLineWidth bw
  c $ setSourceColor bcl
  c $ C.stroke

cTranslate x y = c $ C.translate x y
cRotate a = c $ C.rotate a
cNewPath = c $ C.newPath
cLineTo x y = c $ C.lineTo x y
cMoveTo x y = c $ C.moveTo x y
cRelLineTo x y = c $ C.relLineTo x y
cArc x y r a1 a2 = c $ C.arc x y r a1 a2
cArcNegative x y r a1 a2 = c $ C.arcNegative x y r a1 a2
cClosePath = c $ C.closePath
cStroke = c $ C.stroke
cFill = c $ C.fill
cFillPreserve = c $ C.fillPreserve
cSetSourceColor color = c $ setSourceColor color
cPaint = c $ C.paint
cFontExtents = c $ C.fontExtents
cFontExtentsDescent fe = C.fontExtentsDescent fe
cShowText s = c $ C.showText s

cRenderToPNGFile :: CRender a -> Int -> Int -> FilePath -> IO a
cRenderToPNGFile cr width height path = 
    C.withImageSurface C.FormatARGB32 width height $ \result -> do
    a <- C.renderWith result $ runCRender cr bitmapEnv
    C.surfaceWriteToPNG result path
    return a

cRenderToPDFFile :: CRender a -> Int -> Int -> FilePath -> IO ()
cRenderToPDFFile = cRenderToFile C.withPDFSurface

cRenderToPSFile  ::  CRender a -> Int -> Int -> FilePath -> IO ()
cRenderToPSFile  = cRenderToFile C.withPSSurface

cRenderToSVGFile  ::  CRender a -> Int -> Int -> FilePath -> IO ()
cRenderToSVGFile  = cRenderToFile C.withSVGSurface

cRenderToFile withSurface cr width height path = 
    withSurface path (fromIntegral width) (fromIntegral height) $ \result -> do
    C.renderWith result $ runCRender rfn vectorEnv
    C.surfaceFinish result
  where
    rfn = do
        cr
        c $ C.showPage

bitmapEnv :: CEnv
bitmapEnv = CEnv (adjfn 0.5) (adjfn 0.0)
  where
    adjfn offset (Point x y) = Point (adj x) (adj y)
      where
        adj v = (fromIntegral.round) v +offset

vectorEnv :: CEnv
vectorEnv = CEnv id id