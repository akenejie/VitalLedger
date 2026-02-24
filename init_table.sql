-- テーブルの作成（データベースの新規作成時）
PRAGMA foreign_keys = ON; -- 外部キー制約を有効化

-- ==========================================
-- I. 通貨・財布・価値変動マスタ
-- ==========================================

-- 通貨単位の定義
-- ポイントも「通貨の一種」として扱うため、特別なフラグは用いない。全て等しく「単位」と「変動履歴」を持つ。
CREATE TABLE m_currencies (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	code TEXT NOT NULL UNIQUE,            -- JPY, USD, d_PT, V_PT...
	name TEXT NOT NULL,                   -- 日本円, 米ドル, dポイント...
	display_unit TEXT,                    -- 円, $, pt...
	start_at REAL,                        -- 出現日時（シリアル値）
	end_at REAL,                          -- 消滅日時（シリアル値）
	successor_id INTEGER,                 -- 継承先通貨ID (例: Tポイント -> Vポイント)
	FOREIGN KEY (successor_id) REFERENCES m_currencies(id)
);

-- 円基準の価値変動履歴
CREATE TABLE t_currency_rates (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	currency_id INTEGER,
	rate_to_jpy REAL NOT NULL,            -- 1単位あたりの円価格
	-- VALUE_ADJUST: 為替・ポイントレート変動, QUANTITY_ADJUST: デノミ・併合
	change_type TEXT CHECK(change_type IN ('VALUE_ADJUST', 'QUANTITY_ADJUST')) DEFAULT 'VALUE_ADJUST',
	effective_at REAL NOT NULL,           -- 変動日時（シリアル値）
	FOREIGN KEY (currency_id) REFERENCES m_currencies(id)
);

-- 財布（物理財布、銀行、ポイントなど）
CREATE TABLE m_wallets (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	currency_id INTEGER,
	-- 財布の種類はお金の性質ではなく「管理上の分類」として残す。
	-- RISKYはリスク資産を表し、別の財布から投資する瞬間のお金を保存しておき、価値変動を反映させた後に別の財布に戻す。
	wallet_group TEXT CHECK(wallet_group IN ('CASH', 'BANK', 'POINT', 'RISKY')) DEFAULT 'CASH',
	is_active INTEGER DEFAULT 1,
	closed_at REAL,                       -- 財布廃止日時（シリアル値）
	FOREIGN KEY (currency_id) REFERENCES m_currencies(id)
);

-- ==========================================
-- II. 食品・栄養素共通基盤
-- ==========================================

-- 普遍的食品（野菜・果物など個数管理するもの）
CREATE TABLE m_foods_universal (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	standard_unit_name TEXT,              -- 個, 本, 枚...
	standard_weight_g REAL,
	edible_part_rate REAL DEFAULT 1.0,
	shelf_life_days_guideline REAL,    -- 冷蔵庫管理用の目安期限（買ってから何日、0.5日なら12時間）
	-- 主要栄養素
	energy_kcal REAL, protein_g REAL, fat_g REAL, carb_g REAL, salt_equiv_g REAL,
	-- 味覚10種
	taste_sweet REAL, taste_salty REAL, taste_sour REAL, taste_bitter REAL, taste_umami REAL,
	taste_pungent REAL, taste_cooling REAL, taste_astringency REAL, taste_richness REAL, taste_sharpness REAL
);

-- 計測食品（肉・調味料など100g単位で管理するもの）
CREATE TABLE m_foods_measured (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	is_seasoning INTEGER DEFAULT 1,       -- 調味料フラグ
	-- 主要栄養素
	energy_kcal REAL, protein_g REAL, fat_g REAL, carb_g REAL, salt_equiv_g REAL,
	-- 味覚10種
	taste_sweet REAL, taste_salty REAL, taste_sour REAL, taste_bitter REAL, taste_umami REAL,
	taste_pungent REAL, taste_cooling REAL, taste_astringency REAL, taste_richness REAL, taste_sharpness REAL
);

-- 加工食品・外食（1食・1包装単位で管理するもの）
CREATE TABLE m_foods_processed (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	manufacturer TEXT,                    -- 製造会社、外食チェーン名
	serving_name TEXT DEFAULT '1食',
	weight_per_serving_g REAL,
	-- 主要栄養素
	energy_kcal REAL, protein_g REAL, fat_g REAL, carb_g REAL, salt_equiv_g REAL,
	-- 味覚10種
	taste_sweet REAL, taste_salty REAL, taste_sour REAL, taste_bitter REAL, taste_umami REAL,
	taste_pungent REAL, taste_cooling REAL, taste_astringency REAL, taste_richness REAL, taste_sharpness REAL
);

-- ==========================================
-- III. 店舗・取引・カテゴリ管理
-- ==========================================

-- ブランド名（例: セブンイレブン）
CREATE TABLE m_brands ( id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL );
-- 店舗（例: 新宿駅東口店）
CREATE TABLE m_store_branches (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	brand_id INTEGER,
	branch_name TEXT NOT NULL,            -- 店舗名・支店名
	FOREIGN KEY (brand_id) REFERENCES m_brands(id)
);

-- カテゴリマスタ
--   特殊カテゴリの設定を厳格化。
--   food_typeカラムにより、レシート入力時にどの食品マスタへの入力を強制するかを制御する。
CREATE TABLE m_categories (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	type TEXT CHECK(type IN ('EXPENSE', 'INCOME'))
);

-- 取引
CREATE TABLE t_transactions (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	transaction_name TEXT,
	branch_id INTEGER,                    -- 店舗がない（お小遣い等）場合はNULL可
	transaction_at REAL NOT NULL,         -- 日時（シリアル値）
	is_public INTEGER DEFAULT 1,          -- 0: 秘密の取引（おこづかいなど税なし）
	tax_adjustment_jpy INTEGER DEFAULT 0, -- 基本切り捨てに対する1円単位の調整
	total_amount_jpy INTEGER,             -- 最終的な支払額面（円）
	FOREIGN KEY (branch_id) REFERENCES m_store_branches(id)
);

-- 取引に紐づくレシート画像
-- 1つの取引(t_transactions)に対して複数枚の画像を保持可能とする。
CREATE TABLE t_transaction_images (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	transaction_id INTEGER NOT NULL,      -- 紐付け先の取引ID
	file_name TEXT NOT NULL,              -- 画像のファイル名（またはパス）
	display_order INTEGER DEFAULT 1,      -- 1枚目、2枚目などの表示順
	captured_at REAL,                     -- 撮影/登録日時（シリアル値）
	note TEXT,                            -- メモ（「裏面」「保証書も含む」など）
	FOREIGN KEY (transaction_id) REFERENCES t_transactions(id)
);

-- 商流：商品ごとの明細（ここを全部足すと「支払うべき額」になる）
CREATE TABLE t_transaction_details (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	transaction_id INTEGER,
	category_id INTEGER, -- NULL=特殊カテゴリ

	-- 特殊カテゴリ分類
	--   NONE: 通常カテゴリ: 食品以外（日用品、交通費等。計算ミスや盗難も含む）
	--   ADJUSTMENT: 残高調整（初期設定や統計終了等で、計算ミスや盗難は含まない、これは赤字黒字算出には使用しない）
	--   UNIVERSAL: 野菜等 (m_foods_universalへリンク)
	--   MEASURED: 肉・魚・調味料 (m_foods_measuredへリンク)
	--   PROCESSED: 菓子・レトルト (m_foods_processedへリンク)
	--   OUT_EAT: 外食 (m_foods_processedへリンクするが在庫にはならない)
	-- 「category_id があるなら food_type は必ず 'NONE' である」
	food_type TEXT CHECK(food_type IN ('NONE', 'ADJUSTMENT', 'UNIVERSAL', 'MEASURED', 'PROCESSED', 'OUT_EAT')) DEFAULT 'NONE',

	-- 食品マスタ（food_typeに依存して、UNIVERSAL, MEASURED, PROCESSED3つのうちならば埋める）
	food_id INTEGER,

	item_name_receipt TEXT,
	unit_price_ex_tax REAL,               -- 税抜単価（円）
	quantity REAL NOT NULL,               -- 数量（0.25個など対応）
	content_amount_per_unit REAL,         -- 内容量(g)
	tax_rate REAL NOT NULL,               -- 商品ごとに8%や10%を記録
	discount_amount REAL DEFAULT 0,       -- 商品単位の割引額（円）

	-- 中古・評価
	is_used INTEGER DEFAULT 0,
	condition_rank TEXT CHECK(condition_rank IN ('A','B','C','D','J')),
	estimated_new_price REAL,
	reliability_level INTEGER CHECK(reliability_level BETWEEN 1 AND 3),

	-- 食品管理属性
	origin_area TEXT,                     -- 産地
	-- EAT_NOW: その場で消費（在庫にならない、即時栄養計上）
	-- FRIDGE/FREEZER/PANTRY: 在庫になる
	-- GIFT: 他者へ譲渡（在庫にならず、栄養計上もしない）
	destination TEXT CHECK(destination IN ('EAT_NOW', 'FRIDGE', 'FREEZER', 'PANTRY', 'GIFT')),

	limit_date REAL,                   -- 消費期限か賞味期限（シリアル値）、目安の期限は含めない
	limit_type TEXT CHECK(limit_type IN ('CONSUMPTION', 'BEST_BEFORE')), -- CONSUMPTION: 消費期限、BEST_BEFORE: 賞味期限

	FOREIGN KEY (transaction_id) REFERENCES t_transactions(id),
	FOREIGN KEY (category_id) REFERENCES m_categories(id)
	-- food_idへの外部キー制約は、参照先が動的に変わる（m_foods_universal(id), m_foods_measured(id), m_foods_processed(id)）ため、厳格に行う場合はTRIGGERを使用します。
);

-- ==========================================
-- IV. 資金フロー管理
-- ==========================================

-- 資金移動ログ
--  ポイントに限らず「全ての資金」に対して期限(expiry_at)を持たせる。
--  現金なら expiry_at IS NULL となるだけである。
CREATE TABLE t_payments (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	transaction_id INTEGER,
	wallet_id INTEGER,        -- NULL=おごってもらった
	amount INTEGER NOT NULL,  -- 資産の増減：マイナスは支払い、プラスは受取・還元
	remaining_amount INTEGER NOT NULL, -- 資金移動後（現在でない）の残高スナップショット（高速化のためのおまけの定数、計算ミス→再計算で変化あり）
	expiry_at REAL,           -- この資金バッチの有効期限 (NULL=無期限)。特に期間限定ポイントに用いる。負の移動の場合は負債消滅等に利用可。
	usage_restriction TEXT,   -- NULLなら用途制限なし、文字列があれば「用途限定」	note TEXT,

	-- 資金移動の性質（MAINの合計が商品価格と一致すれば良い）
	-- MAIN: 商品価格との相殺対象 (買い物での支払い、割り勘の支払など)
	-- SUB:  相殺対象外で付随的な移動 (ポイント付与、キャッシュバック)
	-- INDEPENDENT: 相殺対象外で独立した資金移動（給与、利息など）
	payment_type TEXT CHECK(payment_type IN ('MAIN', 'SUB', 'INDEPENDENT')) NOT NULL DEFAULT 'MAIN',

	FOREIGN KEY (transaction_id) REFERENCES t_transactions(id),
	FOREIGN KEY (wallet_id) REFERENCES m_wallets(id)
);

-- 各財布の現在の残高内訳（スナップショット）
CREATE TABLE t_wallet_balances (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	wallet_id INTEGER NOT NULL,

	-- どの資金移動に起因するか
	-- 期限・用途が共に無制限な残高は NULL とする
	origin_payment_id INTEGER, 

	-- 残高単位は財布固有の単位で、ここでは円とは限らない（変数）
	current_amount INTEGER NOT NULL DEFAULT 0,

	updated_at REAL NOT NULL, -- 最終更新日時（シリアル値）

	FOREIGN KEY (wallet_id) REFERENCES m_wallets(id),
	FOREIGN KEY (origin_payment_id) REFERENCES t_payments(id)
);

-- t_paymentsのremaining_amountは資金移動時点の定数で、t_wallet_balancesのcurrent_amountは現在の変数であることに注意

-- ==========================================
-- V. 在庫と食事（在庫消費）
-- ==========================================

-- 冷蔵庫・パントリーの在庫
-- 食品の収支が記録できているので計算すれば残量が割り出せるが、それだと遅いのでスナップショットが目的で、最終更新日時を踏まえて動的に変える
CREATE TABLE t_inventory (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	detail_id INTEGER NOT NULL,           -- どの購入明細に由来するか
	current_quantity REAL NOT NULL,       -- 現在の残量（大根0.25個、肉150gなど）

	updated_at REAL NOT NULL, -- 最終更新日時（シリアル値）

	FOREIGN KEY (detail_id) REFERENCES t_transaction_details(id)
);

CREATE TABLE t_meal_logs (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	eaten_at REAL NOT NULL,               -- いつ消費したか
	note TEXT
);

-- 消費明細
--  在庫(t_inventory)を消費した事実のみを記録する。
--  ※外食やEAT_NOWはここには含まれない（レシート側で完結するため）
CREATE TABLE t_meal_details (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	meal_name TEXT,
	meal_id INTEGER NOT NULL,
	inventory_id INTEGER NOT NULL,
	detail_id INTEGER NOT NULL,           -- 購入明細と直接紐付けて履歴を追跡可能にする
	amount_consumed REAL NOT NULL,        -- 消費量
	-- 消費の性質
	--   EATEN: 食べた（栄養計上対象）
	--   GIFT: プレゼント・他者へ譲渡（栄養計上しない）
	--   LOSS: 腐らせた・廃棄（栄養計上しない）
	consume_type TEXT CHECK(consume_type IN ('SELF', 'GIFT', 'LOSS')) DEFAULT 'SELF',
	FOREIGN KEY (meal_id) REFERENCES t_meal_logs(id),
	FOREIGN KEY (detail_id) REFERENCES t_transaction_details(id)
);

-- ==========================================
-- VI. 還元権利の管理（おまけ）
-- ==========================================

-- 1. 還元権利マスタ
--    計算ロジックの定義。「期間」と「区切り」を持つことで、累計計算を可能にする。
CREATE TABLE m_reward_rules (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,                   -- ルール名 (例: 楽天カード1%, 三井住友カード100万円修行, Tカード提示など)

	-- 還元先
	target_wallet_id INTEGER NOT NULL,    -- ポイントが貯まる財布ID

	-- レート設定 (unit_amount円につき grant_amountポイント)
	-- 例: 200円で1pt -> unit=200, grant=1, 100万円で1万pt -> unit=1000000, grant=10000
	unit_amount INTEGER NOT NULL DEFAULT 200,
	grant_amount INTEGER NOT NULL DEFAULT 1,

	-- 期間集計ロジック
	-- TRANSACTION: 取引ごとに切り捨て計算 (例: 198円なら0pt)
	-- MONTHLY: 毎月指定日の期間内で累計し、閾値を超えた分をその取引で付与
	-- YEARLY: 年間累計
	period_type TEXT CHECK(period_type IN ('TRANSACTION', 'MONTHLY', 'YEARLY')) DEFAULT 'TRANSACTION',

	-- 区切り日 (period_typeが MONTHLY/YEARLY の場合に使用)
	-- 例: MONTHLYで16なら「当月16日〜来月15日」を1つの期間とみなす。
	-- 例: YEARLYで40なら「当年4月9日〜来年4月8日」を1つの期間とみなす。（うるう年を考慮して3月1日からの累計日数を入れる）
	-- 例: NULL・なら「当月1日〜末日」。
	period_start_day INTEGER DEFAULT 1,

	-- 期間内最大還元回数 (0=無制限)
	max_times_per_period INTEGER,

	FOREIGN KEY (target_wallet_id) REFERENCES m_wallets(id)
);

-- 2. 還元対象財布リスト
--    「どの財布から支払った時にこの権利を行使できるか」
--    ※クレジットカード払いは「銀行口座から直接支払った(デビットのような解釈) + クレカ還元権利の行使」の組み合わせで表現。
CREATE TABLE m_reward_source_wallets (
	rule_id INTEGER NOT NULL,
	source_wallet_id INTEGER NOT NULL,
	PRIMARY KEY (rule_id, source_wallet_id),
	FOREIGN KEY (rule_id) REFERENCES m_reward_rules(id),
	FOREIGN KEY (source_wallet_id) REFERENCES m_wallets(id)
);

-- 3. 還元権利行使ログ（資金移動に紐づく配列）
--    ステータス管理は廃止。ここにレコードがある＝ポイント発生（0pt含む）とみなす。
--    累計計算の結果、「今回は繰り上がりで1ptついた」「今回は端数のみで0pt」を即時記録する。
CREATE TABLE t_reward_logs (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	payment_id INTEGER NOT NULL,          -- 元となる支払い（資金移動）ID
	rule_id INTEGER NOT NULL,             -- 行使した還元ルール

	FOREIGN KEY (payment_id) REFERENCES t_payments(id),
	FOREIGN KEY (rule_id) REFERENCES m_reward_rules(id)
);
