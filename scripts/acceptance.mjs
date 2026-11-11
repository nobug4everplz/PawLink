// 四角色權限與核心流程驗收：對「真實」Supabase 專案執行（只用 anon key）。
// 用法：
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... QA_PASSWORD=... node scripts/acceptance.mjs
// 會建立（或重複使用）三個測試帳號 pawlink-qa-{owner,user,care}@<QA_EMAIL_DOMAIN>，
// 測試資料放在外海座標，結束時刪除動物與紀錄並把測試點停用。
// 管理員測試需要先在 SQL Editor 把 pawlink-qa-admin 設成 admin（見 docs/acceptance.md），沒有就略過。
import { createClient } from '@supabase/supabase-js'

const URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_ANON_KEY, PW = process.env.QA_PASSWORD
const DOMAIN = process.env.QA_EMAIL_DOMAIN || 'example.com'
if (!URL || !KEY || !PW) { console.error('缺 SUPABASE_URL / SUPABASE_ANON_KEY / QA_PASSWORD'); process.exit(2) }

const results = []
function ok(name, pass, detail = '') {
  results.push({ name, pass })
  console.log(`${pass ? '✅' : '❌'} ${name}${detail ? '  — ' + detail : ''}`)
}
const client = () => createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } })
async function login(tag, { create = true } = {}) {
  const c = client(), email = `pawlink-qa-${tag}@${DOMAIN}`
  let r = await c.auth.signInWithPassword({ email, password: PW })
  if (r.error && create) {
    r = await c.auth.signUp({ email, password: PW, options: { data: { display_name: `QA-${tag}` } } })
    if (r.error) throw new Error(`註冊 ${email} 失敗：${r.error.message}`)
    if (!r.data.session) throw new Error('註冊後沒有 session：請先在 Supabase 關閉 Confirm email')
  }
  if (r.error) return null
  return { c, id: r.data.user.id, email }
}
// 寫入被擋：回錯誤，或 RLS 讓影響列數為 0
const denied = (r) => !!r.error || (Array.isArray(r.data) && r.data.length === 0)
const allowed = (r) => !r.error && (!Array.isArray(r.data) || r.data.length > 0)
const msg = (r) => r.error ? `${r.error.code || ''} ${r.error.message}` : `rows=${Array.isArray(r.data) ? r.data.length : '-'}`

const LAT = 25.30012, LNG = 122.20034 // 外海，不會干擾 Demo 區域
const guest = client()
const owner = await login('owner'), user = await login('user'), care = await login('care')
const admin = await login('admin', { create: false })
ok('三個測試帳號可註冊／登入', !!(owner && user && care))

// ---------- 清掉上次殘留 ----------
for (const u of [owner, user, care]) {
  await u.c.from('animals').delete().eq('created_by', u.id)
  await u.c.from('feeding_logs').delete().eq('user_id', u.id)
}

// ---------- profiles ----------
{
  const p = await owner.c.from('profiles').select('id,display_name,role').eq('id', owner.id).single()
  ok('註冊後自動建立 profile，角色為 user', p.data?.role === 'user', msg(p))
  ok('訪客讀不到 profiles', denied(await guest.from('profiles').select('id')))
  ok('使用者不能把自己升成 admin（直接改欄位）', denied(await user.c.from('profiles').update({ role: 'admin' }).eq('id', user.id).select()))
  ok('使用者不能呼叫 set_user_role 升權', !!(await user.c.rpc('set_user_role', { p_user_id: user.id, p_role: 'admin' })).error)
  ok('使用者可改自己的暱稱', allowed(await user.c.from('profiles').update({ display_name: 'QA-user' }).eq('id', user.id).select()))
  ok('使用者不能改別人的暱稱', denied(await user.c.from('profiles').update({ display_name: 'hacked' }).eq('id', owner.id).select()))
}

// ---------- 建點 / 30 公尺 ----------
let spotId
{
  const r = await owner.c.rpc('create_feeding_spot', { p_name: 'QA 驗收點', p_lat: LAT, p_lng: LNG, p_description: '門牌秘密描述' })
  spotId = r.data
  ok('登入者可建餵食點', !r.error && !!spotId, msg(r))
  ok('訪客不能建點', !!(await guest.rpc('create_feeding_spot', { p_name: 'x', p_lat: LAT, p_lng: LNG })).error)
  const ct = await owner.c.from('spot_caretakers').select('role').eq('spot_id', spotId).eq('user_id', owner.id).maybeSingle()
  ok('建點者自動成為 owner', ct.data?.role === 'owner', msg(ct))
  // 緯度 1 度 ≈ 110.8 km：+0.00020 ≈ 22m、+0.00036 ≈ 40m
  const n1 = await user.c.rpc('find_nearby_spots', { p_lat: LAT + 0.0002, p_lng: LNG })
  ok('30 公尺提醒：22 公尺處查得到既有點', n1.data?.some((s) => s.id === spotId), msg(n1))
  const n2 = await user.c.rpc('find_nearby_spots', { p_lat: LAT + 0.00036, p_lng: LNG })
  ok('30 公尺提醒：40 公尺處查不到', !n2.error && !n2.data.some((s) => s.id === spotId), msg(n2))
}

// ---------- 訪客模糊化 ----------
{
  const box = { min_lng: LNG - 0.01, min_lat: LAT - 0.01, max_lng: LNG + 0.01, max_lat: LAT + 0.01 }
  const g = (await guest.rpc('get_map_spots', box)).data?.find((s) => s.id === spotId)
  const u = (await user.c.rpc('get_map_spots', box)).data?.find((s) => s.id === spotId)
  const dist = g ? Math.hypot((g.lat - LAT) * 110800, (g.lng - LNG) * 100700) : -1
  ok('訪客地圖看得到點但位置已模糊（偏移 ≤ 71m 且不等於真實位置）', !!g && g.is_fuzzed && dist > 0.5 && dist <= 72, `偏移 ${dist.toFixed(1)}m`)
  ok('登入者拿到精確位置', !!u && !u.is_fuzzed && Math.abs(u.lat - LAT) < 1e-6 && Math.abs(u.lng - LNG) < 1e-6)
  const tiny = { min_lng: LNG - 0.00003, min_lat: LAT - 0.00003, max_lng: LNG + 0.00003, max_lat: LAT + 0.00003 }
  const gt = await guest.rpc('get_map_spots', tiny)
  ok('訪客用極小範圍框真實位置也查不到（除非剛好落在網格中心）', !gt.error && (!gt.data.some((s) => s.id === spotId) || dist < 5))
  const gs = await guest.rpc('get_spot_summary', { p_spot_id: spotId })
  const row = Array.isArray(gs.data) ? gs.data[0] : gs.data
  ok('訪客看不到餵食點描述', !!row && row.description == null, msg(gs))
  ok('訪客不能直接讀 feeding_spots', denied(await guest.from('feeding_spots').select('id')))
  ok('訪客不能讀 feeding_logs（看不到誰餵的）', denied(await guest.from('feeding_logs').select('id')))
  ok('訪客不能讀 spot_caretakers', denied(await guest.from('spot_caretakers').select('spot_id')))
}

// ---------- 餵食點修改權 ----------
{
  ok('一般使用者不能改別人的點', denied(await user.c.from('feeding_spots').update({ name: 'hacked' }).eq('id', spotId).select('id')))
  ok('一般使用者不能刪點', denied(await user.c.from('feeding_spots').delete().eq('id', spotId).select('id')))
  ok('owner 也不能刪點（只能停用）', denied(await owner.c.from('feeding_spots').delete().eq('id', spotId).select('id')))
  ok('使用者不能把自己直接加成 owner', denied(await user.c.from('spot_caretakers').insert({ spot_id: spotId, user_id: user.id, role: 'owner' }).select()))
  ok('使用者不能替別人加入照顧者', denied(await user.c.from('spot_caretakers').insert({ spot_id: spotId, user_id: care.id }).select()))
  const j = await care.c.from('spot_caretakers').insert({ spot_id: spotId, user_id: care.id }).select()
  ok('登入者可自行加入成為照顧者', allowed(j) || j.error?.code === '23505', msg(j))
  ok('照顧者可改自己照顧的點', allowed(await care.c.from('feeding_spots').update({ name: 'QA 驗收點（已改）' }).eq('id', spotId).select('id')))
  ok('照顧者不能把自己升成 owner', denied(await care.c.from('spot_caretakers').update({ role: 'owner' }).eq('spot_id', spotId).eq('user_id', care.id).select()))
  ok('不能竄改 created_by', denied(await care.c.from('feeding_spots').update({ created_by: care.id }).eq('id', spotId).select('id')))
}

// ---------- 記錄餵食 / 腳印 / 2 小時 / 清理 ----------
let logUser
{
  const before = (await guest.rpc('get_spot_summary', { p_spot_id: spotId })).data
  ok('沒餵過的點腳印為紅色 hungry', (Array.isArray(before) ? before[0] : before)?.footprint === 'hungry')
  ok('訪客不能記錄餵食', !!(await guest.rpc('record_feeding', { p_spot_id: spotId })).error)
  // 離線補傳：8 小時前（應為黃色 recent）
  const cid = crypto.randomUUID(), t8 = new Date(Date.now() - 8 * 3600e3).toISOString()
  const r1 = await user.c.rpc('record_feeding', { p_spot_id: spotId, p_food_type: 'dry', p_fed_at: t8, p_client_id: cid })
  ok('一般使用者可記錄餵食（補傳 8 小時前）', !r1.error && !!r1.data, msg(r1))
  const r1b = await user.c.rpc('record_feeding', { p_spot_id: spotId, p_food_type: 'dry', p_fed_at: t8, p_client_id: cid })
  ok('同一 client_id 重送不會產生第二筆', !r1b.error && r1b.data === r1.data, msg(r1b))
  let s = (await guest.rpc('get_spot_summary', { p_spot_id: spotId })).data; s = Array.isArray(s) ? s[0] : s
  ok('6～24 小時前餵過 → 黃色 recent', s?.footprint === 'recent', s?.footprint)
  const c0 = await care.c.rpc('check_recent_feeding', { p_spot_id: spotId })
  ok('2 小時提醒：8 小時前的紀錄不提醒', !c0.error && c0.data.length === 0, msg(c0))
  const r2 = await user.c.rpc('record_feeding', { p_spot_id: spotId, p_food_type: 'wet', p_note: 'QA' })
  logUser = r2.data
  s = (await guest.rpc('get_spot_summary', { p_spot_id: spotId })).data; s = Array.isArray(s) ? s[0] : s
  ok('剛餵過 → 綠色 fresh', s?.footprint === 'fresh', s?.footprint)
  const c1 = await care.c.rpc('check_recent_feeding', { p_spot_id: spotId })
  ok('2 小時提醒：別人會看到「QA-user 幾分鐘前餵過」', c1.data?.length === 1 && !!c1.data[0].fed_by_name, JSON.stringify(c1.data))
  ok('超過 7 天前的補傳被拒', !!(await user.c.rpc('record_feeding', { p_spot_id: spotId, p_fed_at: new Date(Date.now() - 8 * 86400e3).toISOString(), p_client_id: crypto.randomUUID() })).error)
  ok('不能冒名替別人新增餵食紀錄', denied(await user.c.from('feeding_logs').insert({ spot_id: spotId, user_id: owner.id }).select('id')))
  const pend = await user.c.rpc('get_my_pending_cleanups')
  ok('待清理提醒只列出 30 分鐘～24 小時的紀錄（8 小時那筆有、剛餵那筆沒有）',
    pend.data?.some((p) => p.log_id === r1.data) && !pend.data.some((p) => p.log_id === logUser), msg(pend))
  // owner 這個帳號此時不是該筆紀錄本人，但他是照顧者 → 可以代為回報；另開一個沒關係的帳號無法測（三個帳號都有關係），改測訪客
  ok('訪客不能回報清理', !!(await guest.rpc('report_cleanup', { p_log_id: r1.data })).error)
  const cl = await user.c.rpc('report_cleanup', { p_log_id: r1.data })
  ok('本人可回報清理', !cl.error, msg(cl))
  s = (await guest.rpc('get_spot_summary', { p_spot_id: spotId })).data; s = Array.isArray(s) ? s[0] : s
  ok('清理率更新（2 次餵食清理 1 次 = 50%）', Number(s?.clean_rate_30d) === 0.5 && s.feedings_30d === 2 && s.cleaned_30d === 1, JSON.stringify({ r: s?.clean_rate_30d, f: s?.feedings_30d, c: s?.cleaned_30d }))
  ok('照顧者可代為回報該點其他人的清理', !(await care.c.rpc('report_cleanup', { p_log_id: logUser })).error)
  ok('不能刪別人的餵食紀錄', denied(await care.c.from('feeding_logs').delete().eq('id', logUser).select('id')))
  ok('不能竄改餵食時間', denied(await user.c.from('feeding_logs').update({ fed_at: new Date().toISOString() }).eq('id', logUser).select('id')))
}

// ---------- 動物 / TNR / 照片 ----------
let animalId
{
  ok('訪客不能建動物檔', denied(await guest.from('animals').insert({ name: 'x' }).select()))
  const a = await user.c.from('animals').insert({ name: 'QA 小橘', species: 'cat', sex: 'male', tnr_stage: 1 }).select().single()
  animalId = a.data?.id
  ok('一般使用者可建動物檔，預設未結紮', !!animalId && a.data.is_sterilized === false, msg(a))
  ok('建檔者可把動物連到餵食點', allowed(await user.c.from('spot_animals').insert({ spot_id: spotId, animal_id: animalId }).select()))
  ok('訪客可讀動物檔（公開進度）', allowed(await guest.from('animals').select('id,name,tnr_stage,is_sterilized').eq('id', animalId)))
  ok('訪客不能改動物', denied(await guest.from('animals').update({ tnr_stage: 5 }).eq('id', animalId).select('id')))
  // 與前端 updateTnrStage 相同的寫法
  const t = await user.c.from('animals').update({ tnr_stage: 2 }).eq('id', animalId).select('tnr_stage,is_sterilized,tnr_updated_at').single()
  ok('建檔者可更新 TNR 階段（2 誘捕中 → 仍未結紮）', t.data?.tnr_stage === 2 && t.data.is_sterilized === false, msg(t))
  const t3 = await care.c.from('animals').update({ tnr_stage: 3 }).eq('id', animalId).select('tnr_stage,is_sterilized').single()
  ok('照顧者可更新出沒在自己點的動物；階段 3 起自動標記已結紮', t3.data?.is_sterilized === true, msg(t3))
  ok('不能手動改 is_sterilized', denied(await user.c.from('animals').update({ is_sterilized: false }).eq('id', animalId).select('id')))
  ok('TNR 階段超出 1～5 被拒', denied(await user.c.from('animals').update({ tnr_stage: 6 }).eq('id', animalId).select('id')))
  let s = (await guest.rpc('get_spot_summary', { p_spot_id: spotId })).data; s = Array.isArray(s) ? s[0] : s
  ok('餵食點統計：動物 1 隻、已結紮 1 隻', s?.animal_count === 1 && s.sterilized_count === 1, JSON.stringify({ a: s?.animal_count, s: s?.sterilized_count }))

  // 不相關的人：另建一個點與動物，owner 帳號對 user 在別處建的動物沒有權限
  const b = await owner.c.from('animals').insert({ name: 'QA 別人的貓' }).select().single()
  ok('一般使用者不能改別人建的動物（不在自己照顧的點）', denied(await user.c.from('animals').update({ name: 'hacked' }).eq('id', b.data.id).select('id')))
  ok('一般使用者不能刪別人建的動物', denied(await user.c.from('animals').delete().eq('id', b.data.id).select('id')))
  ok('照顧者不能刪別人建的動物（只能改）', denied(await care.c.from('animals').delete().eq('id', animalId).select('id')))

  // 照片：1x1 webp
  const webp = Buffer.from('UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA', 'base64')
  const path = `${animalId}/${crypto.randomUUID()}.webp`
  const up = await user.c.storage.from('animal-photos').upload(path, webp, { contentType: 'image/webp' })
  ok('建檔者可上傳照片到 Storage', !up.error, up.error?.message)
  ok('照片可登記到 animal_photos', allowed(await user.c.from('animal_photos').insert({ animal_id: animalId, storage_path: path }).select()))
  const pub = guest.storage.from('animal-photos').getPublicUrl(path).data.publicUrl
  const head = await fetch(pub)
  ok('訪客可經公開網址看照片', head.ok, String(head.status))
  const up2 = await user.c.storage.from('animal-photos').upload(`${b.data.id}/${crypto.randomUUID()}.webp`, webp, { contentType: 'image/webp' })
  ok('不能上傳照片到別人的動物資料夾', !!up2.error, up2.error?.message)
  ok('訪客不能上傳照片', !!(await guest.storage.from('animal-photos').upload(`${animalId}/g.webp`, webp, { contentType: 'image/webp' })).error)
  const txt = await user.c.storage.from('animal-photos').upload(`${animalId}/a.html`, Buffer.from('<script>1</script>'), { contentType: 'text/html' })
  ok('非圖片檔被 bucket 擋下', !!txt.error, txt.error?.message)
  // 前端查詢（指定外鍵）可正常回傳
  const q = await guest.from('spot_animals').select('animal:animals(id,name,species,tnr_stage,is_sterilized,animal_photos!animal_photos_animal_id_fkey(storage_path,created_at))').eq('spot_id', spotId)
  ok('前端「餵食點的動物列表」查詢正常', !q.error && q.data.length === 1 && q.data[0].animal.animal_photos.length === 1, msg(q))
  await user.c.storage.from('animal-photos').remove([path])
  await owner.c.from('animals').delete().eq('id', b.data.id)
}

// ---------- Realtime ----------
{
  const got = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 25000)
    const ch = owner.c.channel('qa-feeding')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'feeding_logs' }, (p) => { if (p.new?.spot_id === spotId) { clearTimeout(timer); resolve(true) } })
      // SUBSCRIBED 之後資料庫端的監聽還要幾秒才生效（等 1.5 秒時約三次有一次收不到），等 4 秒再寫入
      .subscribe((st) => { if (st === 'SUBSCRIBED') setTimeout(async () => { await care.c.rpc('record_feeding', { p_spot_id: spotId, p_food_type: 'dry' }) }, 4000) })
    void ch
  })
  ok('即時同步：A 記錄餵食，B 的連線收到事件', got)
  await owner.c.removeAllChannels()
}

// ---------- 管理員 ----------
if (admin) {
  const p = await admin.c.from('profiles').select('role').eq('id', admin.id).single()
  if (p.data?.role !== 'admin') console.log('⚠️  pawlink-qa-admin 存在但還不是 admin，略過管理員測試')
  else {
    ok('管理員可改任何餵食點', allowed(await admin.c.from('feeding_spots').update({ description: '管理員改過' }).eq('id', spotId).select('id')))
    ok('管理員可改任何動物', allowed(await admin.c.from('animals').update({ coat: '橘' }).eq('id', animalId).select('id')))
    ok('管理員可用 set_user_role 設定角色', !(await admin.c.rpc('set_user_role', { p_user_id: care.id, p_role: 'user' })).error)
    const tmp = await admin.c.rpc('create_feeding_spot', { p_name: 'QA 待刪點', p_lat: LAT + 0.01, p_lng: LNG })
    ok('管理員可真正刪除餵食點', allowed(await admin.c.from('feeding_spots').delete().eq('id', tmp.data).select('id')))
  }
} else console.log('⚠️  沒有 pawlink-qa-admin 帳號，略過管理員測試（見 docs/acceptance.md）')

// ---------- 階段 2：保育熱區、三層警示、管理員後台 ----------
{
  const probe = await guest.rpc('get_conservation_zones')
  if (probe.error) console.log('⚠️  資料庫還沒套用階段 2 的 migration（20261111000600），略過階段 2 測試：' + probe.error.message)
  else {
    // 測試熱區放在外海，約 1km 見方；北邊界緯度 25.32
    const ZL = 122.215, TOP = 25.32
    const square = { type: 'Polygon', coordinates: [[[122.21, 25.31], [122.22, 25.31], [122.22, 25.32], [122.21, 25.32], [122.21, 25.31]]] }
    const bowtie = { type: 'Polygon', coordinates: [[[122.21, 25.31], [122.22, 25.32], [122.22, 25.31], [122.21, 25.32], [122.21, 25.31]]] }
    const north = (m) => TOP + m / 110800
    const alert = async (c, lat, lng) => { const r = await c.rpc('check_conservation_alert', { p_lat: lat, p_lng: lng }); return r.data?.[0] }
    ok('訪客看得到保育熱區清單', Array.isArray(probe.data))
    ok('訪客不能新增保育熱區', !!(await guest.rpc('save_conservation_zone', { p_name: 'x', p_geojson: square })).error)
    ok('一般使用者不能新增保育熱區', !!(await user.c.rpc('save_conservation_zone', { p_name: 'x', p_geojson: square })).error)
    ok('照顧者不能新增保育熱區', !!(await care.c.rpc('save_conservation_zone', { p_name: 'x', p_geojson: square })).error)
    ok('一般使用者不能看使用者清單（含 Email）', !!(await user.c.rpc('admin_list_users')).error)
    ok('一般使用者不能用餵食點管理清單', !!(await user.c.rpc('admin_list_spots')).error)
    ok('一般使用者不能指派 owner', !!(await user.c.rpc('admin_set_spot_owner', { p_spot_id: spotId, p_user_id: user.id })).error)
    ok('訪客不能查既有餵食點的警示', !!(await guest.rpc('check_spot_conservation_alert', { p_spot_id: spotId })).error)
    const far = await alert(guest, LAT, LNG)
    ok('遠離熱區 → none', far?.level === 'none', JSON.stringify(far))

    const isAdm = admin && (await admin.c.from('profiles').select('role').eq('id', admin.id).single()).data?.role === 'admin'
    if (!isAdm) console.log('⚠️  沒有管理員測試帳號，略過熱區繪製與後台測試')
    else {
      await admin.c.from('conservation_zones').delete().like('name', 'QA %') // 清掉上次殘留
      const bad = await admin.c.rpc('save_conservation_zone', { p_name: 'QA 蝴蝶結', p_geojson: bowtie })
      ok('自我相交的多邊形被擋下（ST_IsValid）', !!bad.error && /交叉/.test(bad.error.message), msg(bad))
      const z = await admin.c.rpc('save_conservation_zone', { p_name: 'QA 外海示意區', p_geojson: square, p_species: '石虎' })
      ok('管理員可新增保育熱區', !z.error && !!z.data, msg(z))
      const list = await guest.rpc('get_conservation_zones')
      const mine = list.data?.find((x) => x.id === z.data)
      ok('熱區清單含範圍與 200 公尺緩衝帶 GeoJSON，預設標為示意', mine?.geojson?.type === 'Polygon' && mine?.buffer_geojson?.type === 'Polygon' && mine?.is_demo === true)
      const a1 = await alert(user.c, 25.315, ZL), a2 = await alert(user.c, north(150), ZL), a3 = await alert(user.c, north(195), ZL), a4 = await alert(user.c, north(206), ZL)
      ok('三層警示：範圍內 → red', a1?.level === 'red' && a1.zone_id === z.data, JSON.stringify(a1))
      ok('三層警示：範圍外 150 公尺 → yellow', a2?.level === 'yellow' && Math.abs(a2.distance_m - 150) < 3, JSON.stringify(a2))
      ok('三層警示邊界：195 公尺 → yellow', a3?.level === 'yellow', JSON.stringify(a3))
      ok('三層警示邊界：206 公尺 → none', a4?.level === 'none', JSON.stringify(a4))
      const sp = await owner.c.rpc('create_feeding_spot', { p_name: 'QA 熱區內的點', p_lat: 25.315, p_lng: ZL })
      const sa = await owner.c.rpc('check_spot_conservation_alert', { p_spot_id: sp.data })
      ok('動物建檔檢查：熱區內的餵食點 → red', sa.data?.[0]?.level === 'red', msg(sa))
      const ls = await admin.c.rpc('admin_list_spots', { p_search: 'QA 熱區內的點' })
      ok('餵食點管理清單標出熱區內的點', ls.data?.some((x) => x.id === sp.data && x.alert_level === 'red'), msg(ls))
      await owner.c.from('feeding_spots').update({ status: 'archived' }).eq('id', sp.data)
      ok('一般使用者不能改保育熱區', denied(await user.c.from('conservation_zones').update({ name: 'hacked' }).eq('id', z.data).select('id')))
      ok('一般使用者不能刪保育熱區', denied(await user.c.from('conservation_zones').delete().eq('id', z.data).select('id')))
      const lu = await admin.c.rpc('admin_list_users', { p_search: 'pawlink-qa-user' })
      ok('管理員可用 Email 搜尋使用者', lu.data?.some((x) => x.id === user.id), msg(lu))
      ok('管理員可指派 owner', !(await admin.c.rpc('admin_set_spot_owner', { p_spot_id: spotId, p_user_id: care.id })).error)
      ok('管理員可停用保育熱區，停用後不再警示',
        allowed(await admin.c.from('conservation_zones').update({ status: 'archived' }).eq('id', z.data).select('id')) && (await alert(user.c, 25.315, ZL))?.level === 'none')
      ok('管理員可刪除保育熱區', allowed(await admin.c.from('conservation_zones').delete().eq('id', z.data).select('id')))
    }
  }
}

// ---------- 階段 3：匿名通報、收件匣、進度公開、交流空間 ----------
{
  const probe = await guest.rpc('report_captcha_required')
  if (probe.error) console.log('⚠️  資料庫還沒套用階段 3 的 migration（20261111000700），略過階段 3 測試：' + probe.error.message)
  else {
    const limited = (r) => !!r.error && /頻繁|10 分鐘|最多|太多/.test(r.error.message)
    ok('訪客不能直接讀 neighbor_reports', denied(await guest.from('neighbor_reports').select('id')))
    ok('訪客不能繞過 RPC 直接寫通報', denied(await guest.from('neighbor_reports').insert({ spot_id: spotId, category: 'mess', description: '直接寫表的通報', ip_hash: 'x' }).select()))
    ok('說明太短的通報被擋下', !!(await guest.rpc('submit_neighbor_report', { p_spot_id: spotId, p_category: 'mess', p_description: '短' })).error)
    let rid = null
    if (probe.data === true) console.log('⚠️  已啟用 Turnstile，腳本無法取得有效 token，略過需要送出通報的項目')
    else {
      const r1 = await guest.rpc('submit_neighbor_report', { p_spot_id: spotId, p_category: 'mess', p_description: 'QA 驗收：飼料盒沒有收' })
      // 同一個網路 1 小時內跑第二次驗收時，第一則就會被頻率限制擋下，這也算正確行為
      if (limited(r1)) console.log('⚠️  這個網路剛剛才通報過，第一則就被頻率限制擋下（1 小時後重跑可測完整流程）')
      else { rid = r1.data; ok('沒登入的居民可以送出通報', !r1.error && !!rid, msg(r1)) }
      // 限制是「同一個來源 IP」。執行環境若經過多個出口 IP（雲端主機、代理），前幾次可能各算各的，
      // 所以連送幾次，只要在出口 IP 用完之前被擋下就算通過；一般手機或家用網路第 2 次就會被擋。
      let blockedAt = 0, last
      for (let i = 2; i <= 5 && !blockedAt; i++) {
        last = await guest.rpc('submit_neighbor_report', { p_spot_id: spotId, p_category: 'noise', p_description: `QA 驗收：馬上再送第 ${i} 次` })
        if (limited(last)) blockedAt = i
      }
      ok('短時間重複送出會被擋', blockedAt > 0, blockedAt ? `第 ${blockedAt} 次送出被擋：${last.error.message}` : msg(last))
    }
    if (rid) {
      const inU = await user.c.rpc('get_my_report_inbox')
      ok('無關的使用者收件匣沒有這則通報', !inU.error && !inU.data.some((x) => x.id === rid), msg(inU))
      ok('無關的使用者查不到通報內容', denied(await user.c.from('neighbor_reports').select('id,description').eq('id', rid)))
      ok('無關的使用者不能處理通報', !!(await user.c.rpc('handle_neighbor_report', { p_report_id: rid, p_status: 'resolved' })).error)
      const inC = await care.c.rpc('get_my_report_inbox')
      ok('照顧者的收件匣收到通報內容', inC.data?.some((x) => x.id === rid && x.description.includes('飼料盒')), msg(inC))
      ok('讀不到 ip_hash 欄位', !!(await care.c.from('neighbor_reports').select('ip_hash').eq('id', rid)).error)
      ok('照顧者可回覆並標記已處理', !(await care.c.rpc('handle_neighbor_report', { p_report_id: rid, p_status: 'resolved', p_response: 'QA 已清理' })).error)
      const pub = await guest.rpc('get_spot_public_reports', { p_spot_id: spotId })
      const row = pub.data?.find((x) => x.id === rid)
      ok('訪客看得到處理狀態與回覆，看不到通報內容', row?.status === 'resolved' && row.response === 'QA 已清理' && !('description' in row) && !('ip_hash' in row), msg(pub))
    }

    // 交流空間
    ok('訪客不能讀貼文', denied(await guest.from('posts').select('id')))
    const p = await user.c.from('posts').insert({ title: 'QA 驗收貼文', body: '測試內容' }).select('id,author_id,status').single()
    if (p.error && /最多/.test(p.error.message)) console.log('⚠️  測試帳號 1 小時內發文已達上限，略過交流空間測試')
    else {
      const pid = p.data?.id
      ok('登入者可發文，作者自動帶入', p.data?.author_id === user.id && p.data.status === 'visible', msg(p))
      ok('不能冒名發文', denied(await user.c.from('posts').insert({ title: 'x', body: 'y', author_id: owner.id }).select()))
      const lp = await care.c.from('posts').select('id,title,author:profiles(display_name),comments(count)').eq('id', pid)
      ok('前端「貼文列表」查詢正常（含作者暱稱與留言數）', !lp.error && lp.data.length === 1 && !!lp.data[0].author?.display_name && lp.data[0].comments?.[0]?.count === 0, msg(lp))
      ok('登入者可留言', !(await care.c.from('comments').insert({ post_id: pid, body: 'QA 留言' })).error)
      ok('不能改別人的貼文', denied(await care.c.from('posts').update({ body: 'hacked' }).eq('id', pid).select('id')))
      ok('不能刪別人的貼文', denied(await care.c.from('posts').delete().eq('id', pid).select('id')))
      ok('一般使用者不能自己隱藏貼文', denied(await care.c.from('posts').update({ status: 'hidden' }).eq('id', pid).select('id')))
      ok('登入者可檢舉', !(await care.c.from('content_flags').insert({ post_id: pid, reason: 'QA 檢舉' })).error)
      ok('同一人不能重複檢舉', (await care.c.from('content_flags').insert({ post_id: pid, reason: '再一次' })).error?.code === '23505')
      ok('一般使用者不能看檢舉清單', !!(await care.c.rpc('admin_list_flags')).error)
      ok('一般使用者不能處理檢舉', !!(await care.c.rpc('moderate_content', { p_target_type: 'post', p_target_id: pid, p_hide: true })).error)
      const isAdm = admin && (await admin.c.from('profiles').select('role').eq('id', admin.id).single()).data?.role === 'admin'
      if (isAdm) {
        const fl = await admin.c.rpc('admin_list_flags')
        ok('管理員看得到檢舉清單', fl.data?.some((x) => x.target_id === pid && x.flag_count === 1), msg(fl))
        ok('管理員可隱藏被檢舉的貼文', !(await admin.c.rpc('moderate_content', { p_target_type: 'post', p_target_id: pid, p_hide: true })).error)
        const hid = await care.c.from('posts').select('id').eq('id', pid)
        ok('被隱藏的貼文其他人看不到', !hid.error && hid.data.length === 0, msg(hid))
        const own = await user.c.from('posts').select('status').eq('id', pid).single()
        ok('作者看得到自己的貼文被隱藏', own.data?.status === 'hidden', msg(own))
      }
      ok('作者可刪除自己的貼文', allowed(await user.c.from('posts').delete().eq('id', pid).select('id')))
    }
  }
}

// ---------- 階段 5 延伸一：失蹤／健康哨兵 ----------
{
  const probe = await user.c.rpc('get_animal_sightings', { p_animal_id: animalId })
  if (probe.error) console.log('⚠️  資料庫還沒套用哨兵的 migration（20261111000900），略過哨兵測試：' + probe.error.message)
  else {
    ok('訪客不能回報目擊', !!(await guest.rpc('report_sighting', { p_animal_id: animalId })).error)
    ok('訪客讀不到目擊紀錄與提醒', denied(await guest.from('sightings').select('id')) && denied(await guest.from('animal_alerts').select('id')))
    ok('不能繞過 RPC 直接寫目擊紀錄', !!(await user.c.from('sightings').insert({ animal_id: animalId })).error)
    ok('不認得的健康狀況被擋下', !!(await user.c.rpc('report_sighting', { p_animal_id: animalId, p_condition: 'sick' })).error)
    const s1 = await user.c.rpc('report_sighting', { p_animal_id: animalId, p_condition: 'normal', p_note: 'QA 目擊' })
    ok('登入者可回報目擊；狀況正常不發提醒', !s1.error && !!s1.data?.sighting_id && !s1.data?.alert_id, msg(s1))
    const seen = await guest.from('animals').select('last_seen_at').eq('id', animalId).single()
    ok('回報後更新最後出現時間', !!seen.data?.last_seen_at && Date.now() - new Date(seen.data.last_seen_at).getTime() < 120000, msg(seen))
    ok('同一人 10 分鐘內重複回報被擋下', !!(await user.c.rpc('report_sighting', { p_animal_id: animalId })).error)
    const s2 = await care.c.rpc('report_sighting', { p_animal_id: animalId, p_condition: 'injured', p_note: 'QA 受傷回報' })
    ok('回報受傷立即發健康提醒（決策表 3 規則 1）', !s2.error && !!s2.data?.alert_id, msg(s2))
    const list = await user.c.rpc('get_animal_sightings', { p_animal_id: animalId })
    ok('登入者可查目擊紀錄（含回報者暱稱）', !list.error && list.data.length === 2 && list.data.every((x) => !!x.reporter_name), msg(list))
    const al = await owner.c.rpc('get_my_animal_alerts')
    const mine = al.data?.find((x) => x.id === s2.data?.alert_id)
    ok('該點照顧者收到健康提醒', mine?.type === 'health' && mine?.condition === 'injured' && mine?.status === 'open', msg(al))
    ok('健康提醒不能標記為失蹤', !!(await owner.c.rpc('resolve_animal_alert', { p_alert_id: s2.data?.alert_id, p_mark_missing: true })).error)
    ok('照顧者可把提醒標記為已處理', !(await owner.c.rpc('resolve_animal_alert', { p_alert_id: s2.data?.alert_id, p_note: 'QA 已處理' })).error)
    const al2 = await owner.c.rpc('get_my_animal_alerts')
    ok('處理後狀態為已處理並留有備註', al2.data?.find((x) => x.id === s2.data?.alert_id)?.status === 'resolved' && al2.data?.find((x) => x.id === s2.data?.alert_id)?.note === 'QA 已處理', msg(al2))
    ok('一般使用者不能手動執行哨兵檢查', !!(await user.c.rpc('admin_run_sentinel')).error)
    const isAdm = admin && (await admin.c.from('profiles').select('role').eq('id', admin.id).single()).data?.role === 'admin'
    if (isAdm) {
      const run = await admin.c.rpc('admin_run_sentinel', { p_run: true })
      ok('管理員可手動執行哨兵檢查', !run.error && typeof run.data?.created === 'number', msg(run))
      ok('每日排程（pg_cron）已啟用', run.data?.scheduled === true, JSON.stringify(run.data))
    }
  }
}

// ---------- 收尾 ----------
{
  ok('建檔者可刪自己的動物', allowed(await user.c.from('animals').delete().eq('id', animalId).select('id')))
  for (const u of [owner, user, care]) await u.c.from('feeding_logs').delete().eq('user_id', u.id)
  const ar = await owner.c.from('feeding_spots').update({ status: 'archived' }).eq('id', spotId).select('id')
  ok('owner 可停用餵食點', allowed(ar), msg(ar))
  const box = { min_lng: LNG - 0.01, min_lat: LAT - 0.01, max_lng: LNG + 0.01, max_lat: LAT + 0.01 }
  const m = await user.c.rpc('get_map_spots', box)
  ok('停用的點不再出現在地圖', !m.error && !m.data.some((s) => s.id === spotId))
  ok('停用的點不能再記錄餵食', !!(await user.c.rpc('record_feeding', { p_spot_id: spotId })).error)
}

const fail = results.filter((r) => !r.pass)
console.log(`\n共 ${results.length} 項，通過 ${results.length - fail.length}，失敗 ${fail.length}`)
if (fail.length) { console.log('失敗項目：\n' + fail.map((f) => ' - ' + f.name).join('\n')); process.exit(1) }
process.exit(0)
