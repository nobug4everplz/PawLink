// 假資料：欄位與 get_map_spots RPC 回傳一致（docs/rpc-api.md）
const base = [25.0174, 121.5398] // 台大附近
const names = ['椰林大道', '醉月湖畔', '總圖後方', '舟山路', '公館河堤', '水源市場', '寶藏巖', '新生南路']
const fp = ['fresh', 'recent', 'hungry']
export const mockSpots = Array.from({ length: 40 }, (_, i) => ({
  id: `mock-${i}`,
  name: `${names[i % names.length]} ${Math.floor(i / names.length) + 1} 號點`,
  lat: base[0] + Math.sin(i * 2.3) * 0.012,
  lng: base[1] + Math.cos(i * 1.7) * 0.015,
  is_fuzzed: false,
  last_fed_at: new Date(Date.now() - (i % 3 === 0 ? 2 : i % 3 === 1 ? 12 : 40) * 3600e3).toISOString(),
  footprint: fp[i % 3],
  animal_count: 1 + (i % 4),
  sterilized_count: i % 3,
  clean_rate_30d: i % 5 === 0 ? null : 0.5 + (i % 5) / 10,
}))
