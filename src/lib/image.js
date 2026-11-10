/** 壓縮成 webp、最長邊 1280。經由 canvas 重繪會丟掉 EXIF（含 GPS），符合「照片去除 GPS」。 */
export async function compressImage(file, maxSide = 1280, quality = 0.8) {
  const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' })
  const scale = Math.min(1, maxSide / Math.max(bmp.width, bmp.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(bmp.width * scale)
  canvas.height = Math.round(bmp.height * scale)
  canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height)
  return new Promise((res, rej) =>
    canvas.toBlob((b) => (b ? res(b) : rej(new Error('圖片壓縮失敗'))), 'image/webp', quality))
}
