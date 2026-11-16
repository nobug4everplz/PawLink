import { reactive } from 'vue'
import { supabase } from './supabase'

/** 全域登入狀態：user 為 null 代表訪客 */
export const auth = reactive({ user: null, profile: null, ready: false })

async function loadProfile(user) {
  auth.user = user
  if (!user) { auth.profile = null; return }
  const { data } = await supabase.from('profiles').select('id,display_name,role').eq('id', user.id).maybeSingle()
  auth.profile = data
}

export async function initAuth() {
  if (!supabase) { auth.ready = true; return }
  const { data } = await supabase.auth.getSession()
  await loadProfile(data.session?.user ?? null)
  supabase.auth.onAuthStateChange((_e, session) => { loadProfile(session?.user ?? null) })
  auth.ready = true
}

export const isLoggedIn = () => !!auth.user
export const isAdmin = () => auth.profile?.role === 'admin'

// Supabase Auth 的錯誤訊息是英文，依錯誤代碼（舊版只有訊息）對照成中文
const AUTH_ERRORS = [
  [['invalid_credentials'], /invalid login credentials/i, 'Email 或密碼不正確'],
  [['email_not_confirmed'], /email not confirmed/i, '這個 Email 還沒完成驗證，請先到信箱點擊驗證連結'],
  [['user_already_exists', 'email_exists'], /already (registered|exists)/i, '這個 Email 已經註冊過了，請直接登入'],
  [['weak_password'], /password should|weak password/i, '密碼太簡單，請至少 6 碼並避免常見密碼'],
  [['email_address_invalid', 'validation_failed'], /(invalid|unable to validate) email/i, 'Email 格式不正確'],
  [['over_request_rate_limit', 'over_email_send_rate_limit'], /rate limit|too many/i, '嘗試次數太多，請稍候幾分鐘再試'],
  [['signup_disabled', 'email_provider_disabled'], /signups? not allowed|disabled/i, '目前暫停開放註冊'],
  [['user_banned'], /banned/i, '這個帳號已被停用'],
]
export function authErrorText(e) {
  const code = e?.code || '', msg = e?.message || ''
  for (const [codes, re, text] of AUTH_ERRORS) if (codes.includes(code) || re.test(msg)) return text
  if (/fetch|network/i.test(msg)) return '連不上伺服器，請確認網路後再試'
  return '登入或註冊失敗，請稍後再試'
}
function authError(e) { const err = new Error(authErrorText(e)); err.cause = e; return err }

export async function signIn(email, password) {
  const { error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw authError(error)
}
export async function signUp(email, password, displayName) {
  const { data, error } = await supabase.auth.signUp({ email, password, options: { data: { display_name: displayName } } })
  if (error) throw authError(error)
  return data // data.session 為 null 代表需要先收信驗證
}
export async function signOut() {
  // 登入者拿到的是精確位置，登出後不留在這支手機上
  try { localStorage.removeItem('pawlink:spots') } catch { /* ignore */ }
  await supabase.auth.signOut()
}
