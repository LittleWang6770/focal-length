# 图标设计

使用内置 image_gen 绘制（2026-09-29）。

视觉：双层镜头圆环中嵌入三根统计柱；蓝灰配色与浅色圆角方形，表达照片镜头与使用频率。

- `AppIcon-source.png`：最终生成原图，保留透明度。
- `AppIcon.png`：1024 px 应用资源。
- `AppIcon.icns`：16–1024 px macOS 图标。

运行 `zsh scripts/build-icon.sh` 可从原图重新打包。`scripts/build.sh` 自动调用它并嵌入应用。

## 最终提示词

Refine this existing macOS app icon, preserving its exact concept and blue-gray/off-white palette: a front-facing lens ring enclosing three histogram bars, on a rounded-square tile with transparent outer margins. Make it rigorously clean and minimal. Remove ALL four small triangular aperture decorations inside the lens. Keep only the two concentric lens rings and exactly three solid vertical bars, medium/tall/short heights, each rectangular with a subtle 3% corner radius, sharing one straight horizontal baseline, fully separate from the rings with generous negative space. Center the three bars horizontally and vertically within the circular lens opening. Use uniform flat solid fills #3D647A and #8FAAB7, uniform off-white #F6F9FA tile. No gradients, grain, texture, highlights, shadows or extra details. The rounded-square tile must have a mathematically smooth clean edge with NO stray pixels, no white fringe, no speckles or paint artifacts anywhere outside it. Actual fully transparent alpha outside the tile. Keep generous equal margins around the rounded square on all four sides. Square high-resolution production icon asset, extremely crisp vector-like finish. No text, labels, numbers, logos or presentation mockup.
