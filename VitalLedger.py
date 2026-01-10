import sqlite3
import datetime
import os
import sys
import difflib
import unicodedata
from datetime import timedelta

# ==========================================
# 0. 定数・ユーティリティ
# ==========================================
DB_NAME = "VitalLedger.sqlite3"
SQL_FILE = "VitalLedger.sql"

def datetime_to_serial(dt):
	"""PythonのdatetimeをExcelシリアル値(REAL)に変換"""
	if dt is None: return None
	delta = dt - datetime.datetime(1899, 12, 30)
	return float(delta.days) + (float(delta.seconds) / 86400)

def serial_to_datetime(serial):
	"""Excelシリアル値をPythonのdatetimeに変換"""
	if serial is None: return None
	base = datetime.datetime(1899, 12, 30)
	delta = timedelta(days=serial)
	return base + delta

def format_serial(serial, fmt="%Y/%m/%d %H:%M"):
	"""シリアル値を読みやすい文字列に"""
	if serial is None: return "---"
	dt = serial_to_datetime(serial)
	return dt.strftime(fmt)

def parse_date_input(val_str):
	"""8桁の数字(YYYYMMDD)をシリアル値に変換"""
	if not val_str: return None
	if len(val_str) == 8 and val_str.isdigit():
		try:
			y = int(val_str[0:4])
			m = int(val_str[4:6])
			d = int(val_str[6:8])
			dt = datetime.datetime(y, m, d)
			return datetime_to_serial(dt)
		except ValueError:
			return None
	return None

def get_month_range(yyyymm_str):
	"""YYYYMM文字列から、その月の開始と終了のシリアル値を返す"""
	if len(yyyymm_str) != 6 or not yyyymm_str.isdigit():
		return None, None
	try:
		y = int(yyyymm_str[0:4])
		m = int(yyyymm_str[4:6])
		start_dt = datetime.datetime(y, m, 1)
		if m == 12:
			next_month = datetime.datetime(y + 1, 1, 1)
		else:
			next_month = datetime.datetime(y, m + 1, 1)
		end_dt = next_month - timedelta(seconds=1)
		return datetime_to_serial(start_dt), datetime_to_serial(end_dt)
	except:
		return None, None

def get_str_width(text):
	"""文字列の表示幅を計算（半角=1, 全角=2）"""
	width = 0
	for c in str(text):
		if unicodedata.east_asian_width(c) in 'FWA':
			width += 2
		else:
			width += 1
	return width

def pad_str(text, width, align='left', fillchar=' '):
	"""指定された表示幅になるようにパディングする"""
	text = str(text) if text is not None else ""
	w = get_str_width(text)
	if w >= width:
		return text

	pad_len = width - w
	padding = fillchar * pad_len

	if align == 'right':
		return padding + text
	elif align == 'center':
		left_pad = fillchar * (pad_len // 2)
		right_pad = fillchar * (pad_len - len(left_pad))
		return left_pad + text + right_pad
	else: # left
		return text + padding

def get_input(prompt, required=True, cast_func=None):
	"""入力補助関数"""
	while True:
		val = input(prompt + ": ").strip()
		if not val:
			if required:
				print("入力が必要です。")
				continue
			else:
				return None
		if cast_func:
			try:
				return cast_func(val)
			except:
				print("形式が正しくありません。")
				continue
		return val

table_map = {
	'UNIVERSAL': 'm_foods_universal',
	'MEASURED': 'm_foods_measured',
	'PROCESSED': 'm_foods_processed',
	'OUT_EAT': 'm_foods_processed' # 外食は加工食品DBを利用
}

# ==========================================
# 1. データベース管理クラス
# ==========================================
class Database:
	def __init__(self):
		self.conn = None
		self.cursor = None
		self.connect()

	def connect(self):
		needs_init = not os.path.exists(DB_NAME)
		self.conn = sqlite3.connect(DB_NAME)
		self.conn.row_factory = sqlite3.Row
		self.cursor = self.conn.cursor()
		self.cursor.execute("PRAGMA foreign_keys = ON;")
		if needs_init: self.init_db_from_file()
		self.ensure_snapshot_tables()

	def init_db_from_file(self):
		if not os.path.exists(SQL_FILE):
			print(f"[Error] {SQL_FILE} が見つかりません。")
			sys.exit(1)
		try:
			with open(SQL_FILE, 'r', encoding='utf-8') as f:
				self.cursor.executescript(f.read())
			self.conn.commit()
			print("DB初期化完了。")
		except Exception as e:
			print(f"DB初期化エラー: {e}")
			sys.exit(1)

	def ensure_snapshot_tables(self):
		try:
			self.cursor.execute("""
				CREATE TABLE IF NOT EXISTS t_wallet_balances (
					wallet_id INTEGER PRIMARY KEY,
					current_amount REAL NOT NULL DEFAULT 0,
					updated_at REAL,
					FOREIGN KEY(wallet_id) REFERENCES m_wallets(id)
				)
			""")

			# --- 追加: 在庫テーブルへの列追加 (Migration) ---
			cur = self.conn.cursor()
			cur.execute("PRAGMA table_info(t_inventory)")
			cols = [info[1] for info in cur.fetchall()]
			if 'expiration_type' not in cols:
				print("DB Update: t_inventory に expiration_type を追加します")
				cur.execute("ALTER TABLE t_inventory ADD COLUMN expiration_type TEXT DEFAULT 'ESTIMATE'")

			self.conn.commit()
		except:
			pass

	def close(self):
		if self.conn: self.conn.close()

# ==========================================
# 2. マスタ登録マネージャ
# ==========================================
class MasterManager:
	def __init__(self, db: Database):
		self.db = db

	def find_items_fuzzy(self, name):
		cur = self.db.cursor
		masters = [
			('m_foods_universal', 'UNIVERSAL'),
			('m_foods_measured', 'MEASURED'),
			('m_foods_processed', 'PROCESSED')
		]

		# 完全一致
		for table, f_type in masters:
			cur.execute(f"SELECT id, name FROM {table} WHERE name = ?", (name,))
			res = cur.fetchone()
			if res:
				return {'exact': {'id': res['id'], 'name': res['name'], 'type': f_type}, 'candidates': []}

		# あいまい検索
		candidates = []
		for table, f_type in masters:
			cur.execute(f"SELECT id, name FROM {table}")
			rows = cur.fetchall()
			names = [r['name'] for r in rows]
			matches = difflib.get_close_matches(name, names, n=3, cutoff=0.4)
			for m in matches:
				for r in rows:
					if r['name'] == m:
						candidates.append({'id': r['id'], 'name': r['name'], 'type': f_type})
						break
		return {'exact': None, 'candidates': candidates}

	def find_food_master_fuzzy(self, search_name):
		"""食品DB(3つのテーブル)からあいまい検索を行う"""
		cur = self.db.cursor
		tables = [
			('m_foods_universal', 'UNIVERSAL'),
			('m_foods_measured', 'MEASURED'),
			('m_foods_processed', 'PROCESSED')
		]
		candidates = []
		for table, f_type in tables:
			cur.execute(f"SELECT id, name FROM {table}")
			rows = cur.fetchall()
			names = [r['name'] for r in rows]
			matches = difflib.get_close_matches(search_name, names, n=3, cutoff=0.4)
			for m in matches:
				for r in rows:
					if r['name'] == m:
						candidates.append({'id': r['id'], 'name': r['name'], 'type': f_type})
						break
		return candidates

	def find_food_master_fuzzy_strict(self, search_name, food_type):
		"""指定された food_type に対応するテーブルのみを検索"""
		cur = self.db.cursor
		table = table_map.get(food_type)
		if not table: return []

		cur.execute(f"SELECT id, name FROM {table}")
		rows = cur.fetchall()
		names = [r['name'] for r in rows]
		matches = difflib.get_close_matches(search_name, names, n=3, cutoff=0.4)

		return [{'id': r['id'], 'name': r['name'], 'type': food_type}
			for r in rows if r['name'] in matches]

	def register_new_food(self, food_name, food_type):
		"""指定された food_type のテーブルにのみ登録"""
		table = table_map.get(food_type)
		cur = self.db.cursor
		cur.execute(f"INSERT INTO {table} (name) VALUES (?)", (food_name,))
		self.db.conn.commit()
		return cur.lastrowid

	def register_new_food_with_input(self, search_query, food_type):
		"""
		ユーザーにマスタ用の名前を入力させ、重複がなければ register_new_food を呼び出す。
		"""
		print(f"\n--- 食品マスタ新規登録 [{food_type}] ---")
		# 1. マスタ名の入力（search_query をデフォルト値とする）
		prompt = f"マスタに登録する食品名を入力してください [デフォルト: {search_query}]: "
		master_name = input(prompt).strip()
		if not master_name:
			master_name = search_query

		# 2. データベースを直接検索して重複チェック
		table = table_map.get(food_type)
		cur = self.db.cursor
		cur.execute(f"SELECT id FROM {table} WHERE name = ?", (master_name,))
		if cur.fetchone():
			print(f"エラー: 「{master_name}」は既に {table} に存在します。")
			return None

		# 3. 登録メソッドを呼び出す
		return self.register_new_food(master_name, food_type)

	def get_wallets_with_currency(self):
		"""
		全ての財布を通貨名(currency_name)と単位(display_unit)付きで取得する
		"""
		cur = self.db.cursor
		sql = """
			SELECT
				w.id,
				w.name,                     -- 財布の名前
				c.name AS currency_name,    -- 通貨の名前（日本円、dポイント等）を別名で取得
				c.display_unit              -- 通貨の単位（円、pt等）
			FROM m_wallets w
			JOIN m_currencies c ON w.currency_id = c.id
			ORDER BY w.id ASC
		"""
		cur.execute(sql)
		return cur.fetchall()

# ==========================================
# 3. レポートマネージャ (完全版)
# ==========================================
class ReportManager:
	def __init__(self, db: Database):
		self.db = db

	# --- 共通ヘルパー: 表出力 ---
	def _print_header(self, cols):
		"""cols = [(text, width, align), ...]"""
		line_parts = []
		div_parts = []
		for text, w, align in cols:
			line_parts.append(pad_str(text, w, align))
			div_parts.append("-" * w)
		print(" | ".join(line_parts))
		print("-+-".join(div_parts))

	def _print_row(self, cols):
		line_parts = []
		for text, w, align in cols:
			line_parts.append(pad_str(text, w, align))
		print(" | ".join(line_parts))

	# --- データ取得ロジック ---
	def _fetch_daily_nutrition(self, start_serial, end_serial):
		"""
		指定期間の栄養素を日別(serial)で集計して辞書で返す
		対象: 'EAT_NOW'(購入時即食) + 'SELF'(在庫消費)
		除外: 廃棄(DISCARD)や譲渡(GIFT)など
		"""
		cur = self.db.cursor
		# 栄養素と味覚のカラム定義 (スキーマに基づき energy_kcal, protein_g, fat_g, carb_g, salt_equiv_g, taste_...)
		base_nutrients = ['energy_kcal', 'protein_g', 'fat_g', 'carb_g', 'salt_equiv_g']
		tastes = ['taste_sweet', 'taste_salty', 'taste_sour', 'taste_bitter', 'taste_umami',
				'taste_pungent', 'taste_cooling', 'taste_astringency', 'taste_richness', 'taste_sharpness']
		all_fields = base_nutrients + tastes

		# 栄養素計算式 (Measuredは100gあたり、それ以外は1単位あたり)
		def calc_field(field):
			return f"""
			SUM(
				CASE
					WHEN f_type = 'MEASURED' THEN qty * (COALESCE(fm.{field}, 0) / 100.0)
					WHEN f_type = 'UNIVERSAL' THEN qty * COALESCE(fu.{field}, 0)
					WHEN f_type IN ('PROCESSED', 'OUT_EAT') THEN qty * COALESCE(fp.{field}, 0)
					ELSE 0
				END
			) as {field}
			"""

		fields_sql = ", ".join([calc_field(f) for f in all_fields])

		sql = f"""
		SELECT
			target_date,
			{fields_sql}
		FROM (
			-- 直接消費 (取引明細のEAT_NOW)
			SELECT
				CAST(t.transaction_at AS INTEGER) as target_date,
				td.food_type as f_type,
				td.food_id as f_id,
				td.quantity as qty
			FROM t_transaction_details td
			JOIN t_transactions t ON td.transaction_id = t.id
			WHERE td.destination = 'EAT_NOW'

			UNION ALL

			-- 在庫消費 (SELF)
			SELECT
				CAST(ml.eaten_at AS INTEGER) as target_date,
				td.food_type as f_type,
				td.food_id as f_id,
				md.amount_consumed as qty
			FROM t_meal_details md
			JOIN t_meal_logs ml ON md.meal_id = ml.id
			JOIN t_transaction_details td ON md.detail_id = td.id
			WHERE md.consume_type = 'SELF'
		) as combined
		LEFT JOIN m_foods_measured fm ON f_id = fm.id AND f_type = 'MEASURED'
		LEFT JOIN m_foods_universal fu ON f_id = fu.id AND f_type = 'UNIVERSAL'
		LEFT JOIN m_foods_processed fp ON f_id = fp.id AND (f_type = 'PROCESSED' OR f_type = 'OUT_EAT')
		WHERE target_date BETWEEN ? AND ?
		GROUP BY target_date
		ORDER BY target_date
		"""

		cur.execute(sql, (int(start_serial), int(end_serial)))
		return cur.fetchall()

	# --- 表示メソッド ---

	def show_wallets(self):
		cur = self.db.cursor
		cur.execute("""
			SELECT w.name, c.display_unit, COALESCE(wb.current_amount, 0) as total
			FROM m_wallets w JOIN m_currencies c ON w.currency_id = c.id
			LEFT JOIN t_wallet_balances wb ON w.id = wb.wallet_id
			WHERE w.is_active = 1 ORDER BY w.id
		""")
		print("\n=== 財布残高 ===")
		cols = [("財布名", 32, 'left'), ("残高", 12, 'right')]
		self._print_header(cols)
		for r in cur.fetchall():
			amt = f"{int(r['total']):,}{r['display_unit']}"
			self._print_row([(r['name'], 32, 'left'), (amt, 12, 'right')])

	def show_inventory(self):
		"""
		最新の在庫一覧を表示。
		期限(limit_date)がない場合、m_foods_universalの目安(shelf_life_days_guideline)
		を購入日に加算して動的に計算し「目安」として表示します。
		"""
		# 1. データの取得
		# t_inventory(残量) -> t_transaction_details(期限、場所、名前)
		# -> t_transactions(購入日) -> m_foods_universal(目安日数)
		sql = """
		SELECT
			inv.id as inv_id,
			td.item_name_receipt,
			inv.current_quantity,
			t.transaction_at,
			td.destination as location,
			td.limit_date,
			td.limit_type,
			u.shelf_life_days_guideline
		FROM t_inventory inv
		JOIN t_transaction_details td ON inv.detail_id = td.id
		JOIN t_transactions t ON td.transaction_id = t.id
		LEFT JOIN m_foods_universal u ON td.food_id = u.id AND td.food_type = 'UNIVERSAL'
		WHERE inv.current_quantity > 0
		ORDER BY COALESCE(td.limit_date, t.transaction_at + COALESCE(u.shelf_life_days_guideline, 9999)) ASC
		"""

		cur = self.db.cursor
		cur.execute(sql)
		rows = cur.fetchall()

		if not rows:
			print("現在、在庫はありません。")
			return

		print("\n=== 食品残高 ===")
		# 2. ヘッダー表示
		cols_config = [("商品名", 32, 'left'), ("場所", 8, 'left'), ("残量", 5, 'right'), ("期限", 12, 'left'), ("期限状態", 12, 'left')]
		self._print_header(cols_config)

		now_serial = datetime_to_serial(datetime.datetime.now())

		for r in rows:
			# --- 期限の決定ロジック ---
			display_date = None
			label = ""

			if r['limit_date']:
				# A. 実期限(入力済み)がある場合
				display_date = r['limit_date']
				label = "(消費)" if r['limit_type'] == 'CONSUMPTION' else "(賞味)"
			elif r['shelf_life_days_guideline'] is not None:
				# B. 実期限はないが、マスタに目安がある場合
				# 購入日(transaction_at) + 目安日数
				display_date = r['transaction_at'] + r['shelf_life_days_guideline']
				label = "(目安)" # 目安

			# 日付文字列の作成
			date_str = format_serial(display_date, "%m/%d") if display_date else "---"

			# 状態（期限切れ・今日が期限のアラート）
			status = ""
			if display_date:
				if display_date < now_serial:
					status = "期限切れ" if r['limit_date'] else "目安期限超過"
				elif display_date < now_serial + 2: # 2日以内
					status = "すぐ"

			# 場所
			location = {'FRIDGE':'冷蔵庫','FREEZER':'冷凍庫','PANTRY':'常温保存'}.get(r['location'], '')

			# 3. 行の表示
			self._print_row([(r['item_name_receipt'], 32, 'left'), (location, 8, 'left'), (f"{r['current_quantity']:>5.1f}", 5, 'right'), (f"{date_str}{label}", 12, 'left'), (status, 12, 'left')])

	def _list_transactions(self, s, e):
		cur = self.db.cursor
		sql = """
			SELECT t.id, t.transaction_at, t.transaction_name, b.name as brand,
			COALESCE(SUM(p.amount),0) as total
			FROM t_transactions t
			LEFT JOIN m_store_branches sb ON t.branch_id=sb.id
			LEFT JOIN m_brands b ON sb.brand_id=b.id
			LEFT JOIN t_payments p ON t.id=p.transaction_id
			WHERE t.transaction_at BETWEEN ? AND ?
			GROUP BY t.id ORDER BY t.transaction_at DESC
		"""
		cur.execute(sql, (s, e))
		rows = cur.fetchall()
		if not rows:
			print("該当なし")
			return

		print(f"\n=== 取引一覧 ({len(rows)}件) ===")
		cols = [("No", 4, 'left'), ("日時", 16, 'left'), ("取引名", 32, 'left'), ("ブランド", 20, 'left'), ("金額", 10, 'right')]
		self._print_header(cols)

		t_ids = []
		for i, r in enumerate(rows):
			name = r['transaction_name'] or "---"
			brand = r['brand']
			amt = f"{int(r['total']):,}"
			dt = format_serial(r['transaction_at'], "%Y/%m/%d %H:%M")
			self._print_row([
				(str(i+1), 4, 'left'), (dt, 16, 'left'), (name, 32, 'left'), (brand, 20, 'left'), (amt, 10, 'right')
			])
			t_ids.append(r['id'])

		while True:
			sel = get_input("詳細No (Enter戻る)", required=False)
			if not sel: break
			if sel.isdigit() and 1 <= int(sel) <= len(t_ids):
				self._show_transaction_detail(t_ids[int(sel)-1])

	def _show_transaction_detail(self, trans_id):
		"""取引詳細の完全表示"""
		cur = self.db.cursor

		# 基本情報
		cur.execute("""
			SELECT t.*, b.name as brand_name, sb.branch_name
			FROM t_transactions t
			LEFT JOIN m_store_branches sb ON t.branch_id = sb.id
			LEFT JOIN m_brands b ON sb.brand_id = b.id
			WHERE t.id=?
		""", (trans_id,))
		t = cur.fetchone()

		title = t['transaction_name'] or t['brand_name'] or "名称なし"
		date_str = format_serial(t['transaction_at'])
		print(f"\n>>> 取引詳細 [ID:{t['id']}] {date_str} {title}")

		# 明細
		print("\n [購入明細]")
		cols_d = [("商品名", 20, 'left'), ("単価", 8, 'right'), ("数量", 6, 'right'), ("小計", 8, 'right'), ("行先", 6, 'center')]
		self._print_header(cols_d)

		cur.execute("SELECT * FROM t_transaction_details WHERE transaction_id=?", (trans_id,))
		details = cur.fetchall()

		calc_sum = 0
		for d in details:
			gross = int(d['unit_price_ex_tax'] * d['quantity'] * (1 + d['tax_rate']))
			calc_sum += gross
			dest_map = {'EAT_NOW':'即食', 'FRIDGE':'冷蔵', 'FREEZER':'冷凍', 'PANTRY':'常温'}
			dest_str = dest_map.get(d['destination'], '他')

			self._print_row([
				(d['item_name_receipt'], 20, 'left'),
				(f"{int(d['unit_price_ex_tax'])}", 8, 'right'),
				(f"{d['quantity']:g}", 6, 'right'),
				(f"{gross}", 8, 'right'),
				(dest_str, 6, 'center')
			])

		print()
		print(f" 計算合計: {calc_sum} 円")
		print(f" 確定総額: {abs(int(t['total_amount_jpy']))} 円 ({'支出' if t['total_amount_jpy'] < 0 else '収入'})")

		# 決済
		print("\n [決済内訳]")
		cols_p = [("財布", 32, 'left'), ("金額", 10, 'right'), ("種別", 6, 'center'), ("備考", 14, 'left')]
		self._print_header(cols_p)

		cur.execute("""
			SELECT p.*, w.name as wallet_name
			FROM t_payments p
			JOIN m_wallets w ON p.wallet_id=w.id
			WHERE transaction_id=?
		""", (trans_id,))

		for p in cur.fetchall():
			io_type = "収入" if p['amount'] > 0 else "支出"
			notes = []
			if p['expiry_at']: notes.append(f"限{format_serial(p['expiry_at'], '%y/%m/%d')}")
			if p['usage_restriction']: notes.append(p['usage_restriction'])
			note_str = " ".join(notes)

			self._print_row([
				(p['wallet_name'], 32, 'left'),
				(f"{abs(int(p['amount']))}", 10, 'right'),
				(io_type, 6, 'center'),
				(note_str, 14, 'left')
			])
		print("")

	def show_recent_transactions(self):
		now = datetime.datetime.now()
		start = datetime_to_serial(now - timedelta(days=30))
		end = datetime_to_serial(now)
		self._list_transactions(start, end)

	def show_monthly_transactions(self):
		ym = get_input("年月(YYYYMM)")
		s, e = get_month_range(ym)
		if s: self._list_transactions(s, e)
		else: print("日付エラー")

	# --- 栄養素レポート機能 ---

	def show_daily_nutrition_report(self, start_serial, end_serial, title="栄養素レポート"):
		"""指定期間の日別集計リストと平均を表示"""
		data = self._fetch_daily_nutrition(start_serial, end_serial)

		s_dt = serial_to_datetime(start_serial)
		e_dt = serial_to_datetime(end_serial)
		days = (e_dt - s_dt).days + 1

		print(f"\n=== {title} ===")
		cols = [
			("日付", 10, 'left'), ("Kcal", 8, 'right'), ("Prot", 6, 'right'),
			("Fat", 6, 'right'), ("Carb", 6, 'right'), ("Salt", 6, 'right')
		]
		self._print_header(cols)

		total_k, total_p, total_f, total_c, total_s = 0, 0, 0, 0, 0

		for i in range(days):
			curr_dt = s_dt + timedelta(days=i)
			curr_serial = int(datetime_to_serial(curr_dt))

			row = data.get(curr_serial, {'kcal':0, 'prot':0, 'fat':0, 'carb':0, 'salt':0})

			d_str = curr_dt.strftime("%m/%d")
			self._print_row([
				(d_str, 10, 'left'),
				(f"{int(row['kcal'])}", 8, 'right'),
				(f"{row['prot']:.1f}", 6, 'right'),
				(f"{row['fat']:.1f}", 6, 'right'),
				(f"{row['carb']:.1f}", 6, 'right'),
				(f"{row['salt']:.1f}", 6, 'right')
			])

			total_k += row['kcal']
			total_p += row['prot']
			total_f += row['fat']
			total_c += row['carb']
			total_s += row['salt']

		print("-" * 50)
		self._print_row([
			("合計", 10, 'center'),
			(f"{int(total_k)}", 8, 'right'),
			(f"{total_p:.0f}", 6, 'right'),
			(f"{total_f:.0f}", 6, 'right'),
			(f"{total_c:.0f}", 6, 'right'),
			(f"{total_s:.0f}", 6, 'right')
		])

		if days > 0:
			self._print_row([
				("1日平均", 10, 'center'),
				(f"{int(total_k/days)}", 8, 'right'),
				(f"{total_p/days:.1f}", 6, 'right'),
				(f"{total_f/days:.1f}", 6, 'right'),
				(f"{total_c/days:.1f}", 6, 'right'),
				(f"{total_s/days:.1f}", 6, 'right')
			])

	def show_recent_month_nutrition(self):
		end_dt = datetime.datetime.now()
		start_dt = end_dt - timedelta(days=29)
		s = datetime_to_serial(start_dt)
		e = datetime_to_serial(end_dt)
		self.show_daily_nutrition_report(s, e, "直近30日の栄養素")

	def show_monthly_nutrition(self):
		ym = get_input("年月(YYYYMM)")
		s, e = get_month_range(ym)
		if s:
			self.show_daily_nutrition_report(s, e, f"{ym} の栄養素")
		else:
			print("日付エラー")

	def show_yearly_nutrition_report(self):
		"""直近1年の月別平均"""
		now = datetime.datetime.now()
		months = []
		for i in range(11, -1, -1):
			d = now - timedelta(days=30*i)
			y, m = d.year, d.month
			months.append((y, m))
		months = sorted(list(set(months)))[-12:]

		print("\n=== 直近1年の栄養素（1日平均） ===")
		cols = [
			("年月", 8, 'left'), ("AvgKcal", 8, 'right'), ("AvgProt", 8, 'right'),
			("AvgFat", 8, 'right'), ("AvgCarb", 8, 'right'), ("AvgSalt", 8, 'right')
		]
		self._print_header(cols)

		for y, m in months:
			ym_str = f"{y}{m:02d}"
			s, e = get_month_range(ym_str)
			if not s: continue

			days = (serial_to_datetime(e) - serial_to_datetime(s)).days + 1
			data = self._fetch_daily_nutrition(s, e)

			t_k, t_p, t_f, t_c, t_s = 0, 0, 0, 0, 0
			for row in data.values():
				t_k += row['kcal']
				t_p += row['prot']
				t_f += row['fat']
				t_c += row['carb']
				t_s += row['salt']

			if days > 0:
				self._print_row([
					(f"{y}/{m:02d}", 8, 'left'),
					(f"{int(t_k/days)}", 8, 'right'),
					(f"{t_p/days:.1f}", 8, 'right'),
					(f"{t_f/days:.1f}", 8, 'right'),
					(f"{t_c/days:.1f}", 8, 'right'),
					(f"{t_s/days:.1f}", 8, 'right')
				])

# ==========================================
# 4. 取引・消費マネージャ (完全版)
# ==========================================
class TransactionManager:
	def __init__(self, db: Database, master_mgr: MasterManager):
		self.db = db
		self.master_mgr = master_mgr

	def create_transaction(self):
		print("\n=== 新規取引入力 ===")
		cur = self.db.cursor
		now_dt = datetime.datetime.now()

		# --- 0. 取引基本設定 (日時・公開設定) ---
		date_prompt = f"取引日時 YYYYMMDDHHMM (Enter: {now_dt.strftime('%Y/%m/%d %H:%M')})"
		date_in = get_input(date_prompt, required=False)
		if date_in and len(date_in) == 12 and date_in.isdigit():
			y, m, d = int(date_in[0:4]), int(date_in[4:6]), int(date_in[6:8])
			H, M = int(date_in[8:10]), int(date_in[10:12])
			tx_date_serial = datetime_to_serial(datetime.datetime(y, m, d, H, M))
		elif date_in and len(date_in) == 8 and date_in.isdigit():
			# 日付のみ指定の場合はその日の00:00
			y, m, d = int(date_in[0:4]), int(date_in[4:6]), int(date_in[6:8])
			tx_date_serial = datetime_to_serial(datetime.datetime(y, m, d, 0, 0))
		else:
			tx_date_serial = datetime_to_serial(now_dt)

		# 公開フラグ (nの場合は「非公式/レシートなし」として税率0%を適用) ※自己責任
		is_pub_in = get_input("正式な取引(公開)ですか？ (y:はい/n:非公開・お小遣い等) [def:y]", required=False)
		is_public = 0 if is_pub_in and is_pub_in.lower() == 'n' else 1

		# A. 店舗情報
		brand_id, branch_id = None, None

		while True:
			b_in = get_input("ブランド名 (Enterでスキップ/rで再入力)", required=False)
			if not b_in: break
			if b_in.lower() == 'r': continue

			# --- ブランド検索 ---
			cur.execute("SELECT id, name FROM m_brands")
			all_brands = cur.fetchall()
			brand_names = [r['name'] for r in all_brands]

			# 完全一致確認
			exact_brand = next((r for r in all_brands if r['name'] == b_in), None)

			if exact_brand:
				brand_id = exact_brand['id']
				print(f" -> ブランド確定: {exact_brand['name']}")
			else:
				# あいまい検索
				matches = difflib.get_close_matches(b_in, brand_names, n=3, cutoff=0.4)
				if matches:
					print("候補ブランド:")
					for i, m in enumerate(matches): print(f" {i+1}: {m}")
					print(" n: 新規登録, r: ブランド入力からやり直し")
					sel = get_input("選択", cast_func=str).lower()
					if sel.isdigit() and 1 <= int(sel) <= len(matches):
						b_in = matches[int(sel)-1]
						brand_id = next(r['id'] for r in all_brands if r['name'] == b_in)
					elif sel == 'r': continue
					else: # n (新規)
						cur.execute("INSERT INTO m_brands (name) VALUES (?)", (b_in,))
						brand_id = cur.lastrowid
				else:
					if get_input(f"'{b_in}' は未登録です。新規登録しますか？ (y/r)", cast_func=str).lower() == 'y':
						cur.execute("INSERT INTO m_brands (name) VALUES (?)", (b_in,))
						brand_id = cur.lastrowid
					else: continue

			# --- 支店検索 ---
			while True:
				br_in = get_input(f"[{b_in}] の店舗名 (支店名/rでブランドからやり直し)", required=True)
				if br_in.lower() == 'r':
					brand_id = None
					break # 内側ループを抜けてブランド入力へ

				cur.execute("SELECT id, branch_name FROM m_store_branches WHERE brand_id=?", (brand_id,))
				all_branches = cur.fetchall()
				branch_names = [r['branch_name'] for r in all_branches]

				exact_branch = next((r for r in all_branches if r['branch_name'] == br_in), None)

				if exact_branch:
					branch_id = exact_branch['id']
					print(f" -> 店舗確定: {exact_branch['branch_name']}")
				else:
					matches = difflib.get_close_matches(br_in, branch_names, n=3, cutoff=0.4)
					if matches:
						print("候補店舗:")
						for i, m in enumerate(matches): print(f" {i+1}: {m}")
						print(" n: 新規登録, r: 店舗入力からやり直し")
						sel = get_input("選択", cast_func=str).lower()
						if sel.isdigit() and 1 <= int(sel) <= len(matches):
							br_in = matches[int(sel)-1]
							branch_id = next(r['id'] for r in all_branches if r['branch_name'] == br_in)
						elif sel == 'r': continue
						else: # n
							cur.execute("INSERT INTO m_store_branches (brand_id, branch_name) VALUES (?, ?)", (brand_id, br_in))
							branch_id = cur.lastrowid
					else:
						if get_input(f"'{br_in}' は未登録です。新規登録しますか？ (y/r)", cast_func=str).lower() == 'y':
							cur.execute("INSERT INTO m_store_branches (brand_id, branch_name) VALUES (?, ?)", (brand_id, br_in))
							branch_id = cur.lastrowid
						else: continue
				break # 支店確定

			if branch_id: break # 全て確定して次の工程(明細入力)へ

		# --- B. 明細入力セクション ---
		item_total = 0
		details = []
		print("\n--- 明細入力 (Enterで終了) ---")
		while True:
			# 1. 商品名入力 (自由記述)
			item_name_receipt = get_input("商品名 (レシート通り)", required=False)
			if not item_name_receipt: break

			# 2. カテゴリ選択
			cur.execute("SELECT id, name FROM m_categories WHERE type='EXPENSE'")
			gen_cats = cur.fetchall()
			print(f"\n[カテゴリ選択: {item_name_receipt}]")
			print("  u: 普遍的食品,")
			print("  m: 計測食品,")
			print("  p: 加工食品,")
			print("  o: 外食")
			print("  a: 残高調整,")
			print("  x: その他(NONE)")
			for c in gen_cats:
				print(f"  {c['id']}: {c['name']}")

			cat_sel = get_input("選択", cast_func=str).lower()

			# 判定用フラグ
			f_type_map = {'u':'UNIVERSAL', 'm':'MEASURED', 'p':'PROCESSED', 'o':'OUT_EAT'}
			final_food_type = f_type_map.get(cat_sel)
			final_category_id = int(cat_sel) if cat_sel.isdigit() else None
			final_food_id = None

			# 3. 食品カテゴリの場合のみ、食品マスタ(食品名)との紐付けループ
			if final_food_type:
				search_query = item_name_receipt
				while True:
					# 指定された種別のテーブルのみを検索
					candidates = self.master_mgr.find_food_master_fuzzy_strict(search_query, final_food_type)
					exact_match = next((c for c in candidates if c['name'] == search_query), None)

					print(f"\n食品マスタ候補 [{final_food_type}] ({search_query}):")
					if candidates:
						for i, c in enumerate(candidates):
							mark = " [完全一致]" if c['name'] == search_query else ""
							print(f"  {i+1}: {c['name']}{mark}")
						if not exact_match: print("  n: この名前で新規マスタ登録")
						print("  s: 別の名前で再検索")

						ans = get_input("選択", cast_func=str).lower()
						if ans.isdigit() and 1 <= int(ans) <= len(candidates):
							final_food_id = candidates[int(ans)-1]['id']
							break
						elif ans == 'n' and not exact_match:
							final_food_id = self.master_mgr.register_new_food_with_input(search_query, final_food_type)
							break
						elif ans == 's':
							search_query = get_input("再検索名")
							continue
					else:
						ans = get_input("候補なし。n: 新規登録, s: 再検索", cast_func=str).lower()
						if ans == 'n':
							final_food_id = self.master_mgr.register_new_food_with_input(search_query, final_food_type)
							break
						else:
							search_query = get_input("再検索名")
							continue

			# 4. 金額・数量・税・期限の入力 (共通)
			price = get_input("単価(税抜)", cast_func=int)
			qty = get_input("数量", cast_func=float)

			# 税率自動判定
			if is_public == 1:
				def_tax = 0.08 if final_food_type in ['UNIVERSAL','MEASURED','PROCESSED'] else 0.10
			else:
				# 非公開取引（お小遣いやレシートなし）は税金計算から除外 ※自己責任
				def_tax = 0.0

			tax_rate = get_input(f"税率 (def:{def_tax})", required=False, cast_func=float) or def_tax

			# 詳細パラメータ (SQL定義のフル活用)
			discount = get_input("割引額(円) [def:0]", required=False, cast_func=float) or 0
			content_amt = get_input("内容量(g等) [def:空]", required=False, cast_func=float)
			origin = get_input("産地 [def:空]", required=False)

			# 在庫情報の処理
			dest = "EAT_NOW"
			if final_food_type == 'OUT_EAT':
				print("  -> 外食のため、即食（栄養として計上）として処理します。")
			elif final_food_type in ['UNIVERSAL', 'MEASURED', 'PROCESSED']:
				print("行き先: 1.即食, 2.冷蔵庫, 3.冷凍庫, 4.常温保存, 5.譲渡")
				d_idx = input("> ").strip()
				dest = {'1':'EAT_NOW','2':'FRIDGE','3':'FREEZER','4':'PANTRY','5':'GIFT'}.get(d_idx, 'EAT_NOW')

			# 期限設定のロジック
			limit_date = None
			limit_type = None

			if dest in ['FRIDGE', 'FREEZER', 'PANTRY']:
				date_in = input("賞味期限又は消費期限(YYYYMMDD) [無ければ空]: ").strip()
				if date_in:
					limit_date = parse_date_input(date_in)
					# 1.消費期限, 2.賞味期限 を選択（あるいはデフォルト設定）
					t_sel = input("種類 (1.消費期限, 2.賞味期限) [デフォルト消費期限]: ").strip()
					limit_type = 'BEST_BEFORE' if t_sel == '2' else 'CONSUMPTION'

			# リストに追加
			details.append({
				'item_name_receipt': item_name_receipt,
				'food_id': final_food_id,
				'food_type': final_food_type,
				'category_id': final_category_id,
				'price': price,
				'qty': qty,
				'tax': tax_rate,
				'dest': dest,
				'limit_date': limit_date,
				'limit_type': limit_type,
				'discount': discount,
				'content': content_amt,
				'origin': origin
			})
			# 合計計算 (割引を考慮)
			line_gross = (price * qty) - discount
			if line_gross < 0: line_gross = 0
			item_total += int(line_gross * (1 + tax_rate))

		# --- D. 保存処理 ---
		cur.execute("INSERT INTO t_transactions (branch_id, transaction_at, total_amount_jpy, is_public) VALUES (?, ?, ?, ?)", (branch_id, tx_date_serial, item_total, is_public))
		trans_id = cur.lastrowid
		for d in details:
			cur.execute("""
				INSERT INTO t_transaction_details
				(transaction_id, item_name_receipt, food_id, food_type, category_id, unit_price_ex_tax, quantity, tax_rate, destination, limit_date, limit_type, discount_amount, content_amount_per_unit, origin_area)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			""", (trans_id, d['item_name_receipt'], d['food_id'], d['food_type'], d['category_id'], d['price'], d['qty'], d['tax'], d['dest'], d['limit_date'], d['limit_type'], d['discount'], d['content'], d['origin']))

			# 在庫(食品のみ)
			if d['dest'] in ['FRIDGE', 'FREEZER', 'PANTRY']:
				cur.execute("""
					INSERT INTO t_inventory (detail_id, current_quantity, updated_at)
					VALUES (?, ?, ?)
				""", (cur.lastrowid, d['qty'], tx_date_serial))

		# D. 決済処理
		print(f"\n合計金額: {item_total}円")

		# 決済ロジック（財布選択・限定マネー消費）を起動
		self.handle_payment(trans_id)

		t_name = get_input("取引名")
		if t_name: cur.execute("UPDATE t_transactions SET transaction_name=? WHERE id=?", (t_name, trans_id))
		self.db.conn.commit()
		print("取引登録完了")

	def update_balance_snapshot(self, wallet_id, amount_delta, payment_id, expiry, restriction):
		"""
		t_wallet_balances を更新するヘルパー関数
		- wallet_id: 対象財布
		- amount_delta: 増減額（今回動いた金額）
		- payment_id: 今回作成された t_payments のID (最新の origin として使用)
		- expiry, restriction: 期間・用途属性
		"""
		now_serial = datetime_to_serial(datetime.datetime.now())
		cur = self.db.cursor

		# 1. 更新対象のバランスレコードを探す
		# 属性（期限・用途）が一致する残高レコードを検索
		target_balance_id = None

		if expiry is None and restriction is None:
			# 通常のお金（無制限・無期限）: origin_payment_id が NULL のレコード
			cur.execute("""
				SELECT id FROM t_wallet_balances
				WHERE wallet_id = ? AND origin_payment_id IS NULL
			""", (wallet_id,))
		else:
			# 特殊なお金: 紐付いている t_payments の属性が一致するレコード
			cur.execute("""
				SELECT wb.id 
				FROM t_wallet_balances wb
				JOIN t_payments p ON wb.origin_payment_id = p.id
				WHERE wb.wallet_id = ? 
				AND p.expiry_at IS ? 
				AND p.usage_restriction IS ?
			""", (wallet_id, expiry, restriction))

		row = cur.fetchone()

		if row:
			# A. 既存レコードの更新
			target_balance_id = row[0]

			# 期間・用途がある場合のみ、起源(origin)を今回の最新IDに書き換える
			# (通常のお金は origin=NULL のまま維持)
			if expiry is None and restriction is None:
				sql = "UPDATE t_wallet_balances SET current_amount = current_amount + ?, updated_at = ? WHERE id = ?"
				cur.execute(sql, (amount_delta, now_serial, target_balance_id))
			else:
				sql = "UPDATE t_wallet_balances SET current_amount = current_amount + ?, origin_payment_id = ?, updated_at = ? WHERE id = ?"
				cur.execute(sql, (amount_delta, payment_id, now_serial, target_balance_id))

		else:
			# B. 新規レコードの作成
			origin_val = None if (expiry is None and restriction is None) else payment_id
			cur.execute("""
				INSERT INTO t_wallet_balances (wallet_id, origin_payment_id, current_amount, updated_at)
				VALUES (?, ?, ?, ?)
			""", (wallet_id, origin_val, amount_delta, now_serial))

	def handle_payment(self, trans_id):
		cur = self.db.cursor
		print("\n=== 決済・資金移動入力 ===")

		while True:
			# 1. 財布選択
			wallets = self.master_mgr.get_wallets_with_currency()
			print("\n[財布一覧]")
			for i, w in enumerate(wallets):
				print(f"  {i+1}: {w['name']} ({w['currency_name']})")

			sel_idx = get_input("選択 (Enterで終了)", required=False)
			if not sel_idx: break

			w = wallets[int(sel_idx) - 1]
			wallet_id, unit = w['id'], w['display_unit']

			# 2. 今回の移動総額を入力 (支出は正、収入は負)
			amt_in = get_input(f"移動総額 [{unit}] (正:支出, 負:収入)", cast_func=int)
			current_move_amt = -amt_in  # DB上は 資産増(収入)が正 / 資産減(支出)が負

			# --- 相殺処理フェーズ ---
			# 今回の移動と逆の符号を持つ「限定お金」を検索
			search_sign = "> 0" if current_move_amt < 0 else "< 0"
			cur.execute(f"""
				SELECT id, remaining_amount, expiry_at, usage_restriction, transaction_id
				FROM t_payments
				WHERE wallet_id = ? AND remaining_amount {search_sign}
				AND (expiry_at IS NOT NULL OR usage_restriction IS NOT NULL)
				ORDER BY transaction_id ASC
			""", (wallet_id,))
			limited_records = cur.fetchall()

			# 属性（期限・用途）ごとに合算して集計
			groups = {}
			for r in limited_records:
				key = (r['expiry_at'], r['usage_restriction'])
				if key not in groups: groups[key] = {'total': 0, 'items': []}
				groups[key]['total'] += r['remaining_amount']
				groups[key]['items'].append(r)

			# 各属性グループごとに相殺するか順次確認
			for key, group in groups.items():
				exp, restr = key
				attr_str = f"(期限:{format_serial(exp)}, 制限:{restr})"
				total = group['total']

				print(f"\n [{attr_str}] 残高: {abs(total)}{unit}")

				move = get_input(f" この属性からいくら相殺しますか？ (デフォルト:{abs(total)})",
									   required=False, cast_func=int)
				if move is None: move = abs(total)

				if move > 0:
					# 制限付き資産はお金を減る方に動かし、制限付き負債はお金を増やす方に動かす
					move = move if total < 0 else -move
					# 新しい移動レコードの作成 (t_payments)
					cur.execute("""
						INSERT INTO t_payments (transaction_id, wallet_id, amount, remaining_amount, expiry_at, usage_restriction)
						VALUES (?, ?, ?, ?, ?, ?)
					""", (trans_id, wallet_id, move, total + move, exp, restr))
					new_pay_id = cur.lastrowid
					self.update_balance_snapshot(wallet_id, move, new_pay_id, exp, restr)
					# 今回の移動総額から相殺分を差し引く
					current_move_amt -= move

			# --- 新規属性付与フェーズ ---
			# 相殺しきれなかった残額がある場合
			if abs(current_move_amt) > 0.0001:
				new_exp, new_restr, rem_val = None, None, 0

				if get_input(f" {abs(current_move_amt)}{unit} を期間限定または用途制限のお金にしますか？ (y/n)", required=False).lower() == 'y':
					new_exp_in = get_input("  期限YYYYMMDD (任意)", required=False)
					new_exp = parse_date_input(new_exp_in) if new_exp_in else None
					new_restr = get_input("  用途制限 (任意)", required=False)
					rem_val = current_move_amt # 新規限定お金として残高を保持

				# 移動レコードの作成
				cur.execute("""
					INSERT INTO t_payments (transaction_id, wallet_id, amount, remaining_amount, expiry_at, usage_restriction)
					VALUES (?, ?, ?, ?, ?, ?)
				""", (trans_id, wallet_id, current_move_amt, rem_val, new_exp, new_restr))
				new_pay_id = cur.lastrowid
				self.update_balance_snapshot(wallet_id, current_move_amt, new_pay_id, new_exp, new_restr)
		print("\n--- 全ての決済移動（Payment配列）の登録を完了しました ---")

	def _record_payment_and_usage(self, trans_id, wallet_id, db_amount, expiry):
		"""標準的な支出の記録"""
		self.db.cursor.execute("""
			INSERT INTO t_payments (transaction_id, wallet_id, amount, remaining_amount)
			VALUES (?, ?, ?, 0)
		""", (trans_id, wallet_id, db_amount))

	def consume_inventory(self):
		print("\n=== 在庫消費入力 ===")
		ReportManager(self.db).show_inventory()

		# 日時入力
		now_dt = datetime.datetime.now()
		date_prompt = f"消費日時 YYYYMMDDHHMM (Enter: {now_dt.strftime('%Y/%m/%d %H:%M')})"
		date_in = get_input(date_prompt, required=False)
		if date_in and len(date_in) == 12 and date_in.isdigit():
			y, m, d, H, M = int(date_in[:4]), int(date_in[4:6]), int(date_in[6:8]), int(date_in[8:10]), int(date_in[10:])
			consume_serial = datetime_to_serial(datetime.datetime(y, m, d, H, M))
		else:
			consume_serial = datetime_to_serial(now_dt)
		cur = self.db.cursor

		# 食事ログ作成
		cur.execute("INSERT INTO t_meal_logs (eaten_at, note) VALUES (?, '')", (consume_serial,))
		mid = cur.lastrowid

		total_items = 0
		while True:
			iid = get_input("消費する在庫ID (Enter終了)", required=False)
			if not iid: break
			iid = int(iid)

			cur.execute("SELECT current_quantity, detail_id FROM t_inventory WHERE id=?", (iid,))
			row = cur.fetchone()
			if not row:
				print("IDが見つかりません")
				continue

			use = get_input(f"消費量 (残: {row['current_quantity']:g})", cast_func=float)
			if use > row['current_quantity']:
				print("在庫不足です")
				continue

			# 消費タイプ確認 (SQL定義の活用)
			# SELF:食べた, GIFT:譲渡, LOSS:廃棄
			ctype_in = get_input("タイプ (1:食べる, 2:廃棄, 3:譲渡) [def:1]", required=False)
			c_type = {'1':'SELF', '2':'LOSS', '3':'GIFT'}.get(ctype_in, 'SELF')

			cur.execute("INSERT INTO t_meal_details (meal_id, inventory_id, detail_id, amount_consumed, consume_type) VALUES (?,?,?,?,?)",
						(mid, iid, row['detail_id'], use, c_type))

			cur.execute("UPDATE t_inventory SET current_quantity=current_quantity-? WHERE id=?", (use, iid))
			total_items += 1

		if total_items > 0:
			mn = get_input("メニュー名/メモ", required=False)
			if mn:
				cur.execute("UPDATE t_meal_details SET meal_name=? WHERE meal_id=?", (mn, mid))
				cur.execute("UPDATE t_meal_logs SET note=? WHERE id=?", (mn, mid))
			self.db.conn.commit()
			print("消費完了")
		else:
			# 何も消費しなかった場合はログを消す
			cur.execute("DELETE FROM t_meal_logs WHERE id=?", (mid,))
			self.db.conn.commit()
			print("キャンセルしました")

# ==========================================
# 5. Main Loop
# ==========================================
class LifeManagerApp:
	def __init__(self):
		self.db = Database()
		self.master = MasterManager(self.db)
		self.reporter = ReportManager(self.db)
		self.trans = TransactionManager(self.db, self.master)

	def run(self):
		while True:
			print("\n" + "="*36)
			print(" 生活管理 DB System")
			print("="*36)
			print(" [入力]")
			print(" 1. 取引入力 (買物・収入)")
			print(" 2. 在庫消費 (料理・食べる)")
			print(" [一覧]")
			print(" 3. 直近1ヶ月の取引一覧")
			print(" 4. 月指定で取引一覧")
			print(" [レポート]")
			print(" 5. 直近1ヶ月の栄養素 (日別リスト)")
			print(" 6. 月指定で栄養素 (日別リスト)")
			print(" 7. 直近1年の栄養素 (月別平均)")
			print(" 8. 資産・在庫レポート")
			print(" q. 終了")

			c = input("選択 > ").strip().lower()
			if c == '1': self.trans.create_transaction()
			elif c == '2': self.trans.consume_inventory()
			elif c == '3': self.reporter.show_recent_transactions()
			elif c == '4': self.reporter.show_monthly_transactions()
			elif c == '5': self.reporter.show_recent_month_nutrition()
			elif c == '6': self.reporter.show_monthly_nutrition()
			elif c == '7': self.reporter.show_yearly_nutrition_report()
			elif c == '8':
				self.reporter.show_wallets()
				self.reporter.show_inventory()
			elif c == 'q':
				self.db.close()
				break

if __name__ == "__main__":
	LifeManagerApp().run()
