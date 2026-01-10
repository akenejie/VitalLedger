PRAGMA foreign_keys = ON;

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
	-- 財布の種類はお金の性質ではなく「管理上の分類」として残すが、論理的な扱いは全て同等とする
	wallet_group TEXT CHECK(wallet_group IN ('CASH', 'BANK', 'CREDIT', 'PREPAID', 'POINT')) DEFAULT 'CASH',
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

-- ＜初期設定＞

-- ==========================================
-- I. 通貨・財布・価値変動マスタ
-- ==========================================

-- 1. 通貨・ポイント定義
--   start_at / end_at の算出根拠:
--   ゴールドポイント: 1989/04/01 開始 (32599)
--   楽天ポイント: 2002/07/01 開始 (37438)
--   Tポイント: 2003/10/01 開始 (37895) -> 2024/04/21 終了 = 2024/04/22 0:00 (45404)
--   nanaco: 2007/04/23 開始 (39195)
--   WAON: 2007/04/27 開始 (39199)
--   Amazon: 2007/08/30 開始 (39199)
--   Ponta: 2010/03/01 開始 (40238)
--   dポイント: 2015/12/01 開始 (42339)
--   PayPay: 2018/10/05 開始 (43378)
--   Vポイント: 2020/06/01 名称変更開始 (43983) -> 2024/04/22 統合リニューアル
INSERT INTO m_currencies (id, code, name, display_unit, start_at, end_at, successor_id) VALUES 
(1, 'JPY', '日本円', '円', NULL, NULL, NULL),
(2, 'G_PT', 'ゴールドポイント', 'pt', 32599.0, NULL, NULL),
(3, 'R_PT', '楽天ポイント', 'pt', 37438.0, NULL, NULL),
(4, 'T_PT', 'Tポイント', 'pt', 37895.0, 45404.0, 5), -- Tポイントは 2024/04/22 00:00:00 (45404.0) に終了
(5, 'N_PT', 'nanacoポイント', 'pt', 39195.0, NULL, NULL),
(6, 'W_PT', 'WAONポイント', 'pt', 39199.0, NULL, NULL),
(7, 'A_PT', 'Amazonポイント', 'pt', 39324.0, NULL, NULL), -- 2007/08/30 導入
(8, 'P_PT', 'Pontaポイント', 'pt', 40238.0, NULL, NULL),
(9, 'D_PT', 'dポイント', 'pt', 42339.0, NULL, NULL),
(10, 'P_PAY', 'PayPayポイント', 'pt', 43378.0, NULL, NULL),
(11, 'V_PT', 'Vポイント', 'pt', 43983.0, NULL, NULL); -- Vポイントは元々存在し(2020/06/01~)、2024/04/22 00:00:00 に統合・リニューアル

-- 2. 円基準の価値変動履歴
INSERT INTO t_currency_rates (currency_id, rate_to_jpy, change_type, effective_at)
SELECT id, 1.0, 'VALUE_ADJUST', COALESCE(start_at, 0) FROM m_currencies;

-- 3. ユーザの財布定義 (2026/01/01開始・残高ゼロ)
INSERT INTO m_wallets (id, name, currency_id, wallet_group, is_active) VALUES 
(1, '携帯用財布', 1, 'CASH', 1),
(2, 'メイン銀行口座', 1, 'BANK', 1),
(3, '自宅金庫', 1, 'CASH', 1),
(4, 'ヨドバシゴールドポイント', 2, 'POINT', 1),
(5, 'Vポイント', 11, 'POINT', 1);

-- ==========================================
-- II. 食品・栄養素データの初期投入
-- ==========================================

-- 1. 普遍的食品 (野菜など: 個数/本数管理)
INSERT INTO m_foods_universal (
  name, standard_unit_name, standard_weight_g, edible_part_rate, shelf_life_days_guideline,
  energy_kcal, protein_g, fat_g, carb_g, salt_equiv_g,
  taste_sweet, taste_salty, taste_sour, taste_bitter, taste_umami, taste_pungent, taste_cooling, taste_astringency, taste_richness, taste_sharpness
) VALUES
('大根', '本', 1000.0, 0.95, 7.0, 15.0, 0.4, 0.1, 3.2, 0.0, 2.5, 0.0, 0.0, 0.5, 1.2, 1.5, 0.0, 0.0, 1.0, 3.0),
('キャベツ', '個', 1200.0, 0.85, 10.0, 23.0, 1.3, 0.2, 5.2, 0.0, 3.5, 0.0, 0.0, 0.2, 1.5, 0.0, 0.0, 0.0, 1.5, 1.0),
('卵', '個', 60.0, 1.0, 14.0, 142.0, 12.3, 10.3, 0.3, 0.4, 0.5, 1.0, 0.0, 0.0, 4.5, 0.0, 0.0, 0.0, 6.0, 1.0);

-- 2. 計測食品 (調味料など: 100g基準)
INSERT INTO m_foods_measured (
  name, is_seasoning,
  energy_kcal, protein_g, fat_g, carb_g, salt_equiv_g,
  taste_sweet, taste_salty, taste_sour, taste_bitter, taste_umami, taste_pungent, taste_cooling, taste_astringency, taste_richness, taste_sharpness
) VALUES
('豆板醤', 1, 100.0, 10.0, 5.0, 15.0, 12.0, 1.0, 9.0, 1.5, 0.5, 5.5, 9.0, 0.0, 0.5, 6.0, 4.0),
('醤油', 1, 71.0, 7.7, 0.0, 7.9, 14.5, 1.5, 10.0, 2.0, 0.5, 8.5, 0.0, 0.0, 1.0, 5.0, 5.0),
('パン(食パン)', 0, 248.0, 9.3, 4.4, 46.7, 1.2, 2.0, 1.5, 0.0, 0.0, 1.5, 0.0, 0.0, 0.0, 3.0, 1.0);

-- 3. 加工食品・外食 (1食/1個単位)
INSERT INTO m_foods_processed (
  name, manufacturer, serving_name, weight_per_serving_g,
  energy_kcal, protein_g, fat_g, carb_g, salt_equiv_g,
  taste_sweet, taste_salty, taste_sour, taste_bitter, taste_umami, taste_pungent, taste_cooling, taste_astringency, taste_richness, taste_sharpness
) VALUES
('牛丼(並)', '吉野家', '1杯', 350.0, 230.0, 8.5, 14.0, 18.0, 1.5, 4.0, 4.5, 0.0, 0.0, 5.0, 1.0, 0.0, 0.0, 7.0, 2.0),
('プレミアムロールケーキ', 'ローソン', '1個', 100.0, 315.0, 4.5, 22.0, 24.5, 0.2, 9.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 8.0, 1.0);

-- ==========================================
-- III. 店舗・取引・カテゴリ管理
-- ==========================================

-- 1. ブランド名
INSERT INTO m_brands (id, name) VALUES (1, 'セブンイレブン'), (2, '吉野家'), (3, 'Amazon'), (4, 'ライフ');

-- 2. 店舗
INSERT INTO m_store_branches (brand_id, branch_name) VALUES
(1, '新宿駅靖国通り店'),
(2, '新宿駅東口店'),
(3, 'Amazon.co.jp店'),
(4, '中野駅前店');

-- 3. カテゴリ (m_categories): food_type はデフォルトの 'NONE'
INSERT INTO m_categories (name, type) VALUES 
-- 一般支出カテゴリ（食品以外）
('日用品', 'EXPENSE'),
('家具', 'EXPENSE'),
('PC関連', 'EXPENSE'),
('趣味美容', 'EXPENSE'),
('フォーマル美容', 'EXPENSE'),
('請求料・手数料', 'EXPENSE'),
('交通費', 'EXPENSE'),
('プレゼント', 'EXPENSE'),
('経験（体験）料', 'EXPENSE'),
('病院', 'EXPENSE'),
('仕事', 'EXPENSE'),
-- 収入カテゴリ
('給与', 'INCOME'),
('お小遣い', 'INCOME'),
('還元・キャッシュバック', 'INCOME'),
-- 不定なカテゴリ
('盗難・謎収入', NULL);

-- 4. 取引: データ無しとする

-- 5. 商流: データ無しとする

-- ==========================================
-- IV. 資金フロー管理
-- ==========================================

-- 1. 初期残高レコードの作成 (全て0)
INSERT INTO t_payments (wallet_id, amount, remaining_amount, expiry_at)
SELECT id, 0, 0, NULL FROM m_wallets;

-- 2. 各財布の残高スナップショット: 2026/01/01開始で0円とする
INSERT INTO t_wallet_balances (wallet_id, current_amount, updated_at)
SELECT id, 0, 46023.0 FROM m_wallets; -- 46023=2026/01/01

-- ==========================================
-- V. 在庫と食事（在庫消費）
-- ==========================================

-- データ無しとする	
