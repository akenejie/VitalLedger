-- 初期設定（データベースの新規作成後、テーブルの作成後）
-- このファイルはデータベースの使用例です。

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
(4, '投資信託', 1, 'RISKY', 1),
(5, 'ヨドバシゴールドポイント', 2, 'POINT', 1),
(6, 'Vポイント', 11, 'POINT', 1);

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
('盗難・謎収入', NULL),
('投資価値変動', NULL);

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

-- ==========================================
-- VI. 還元権利の管理 初期設定
-- ==========================================

-- 1. 還元ルール定義 (m_reward_rules)
--   ID 1: 三井住友カード(NL)想定 (200円で1pt、毎月15日締め翌月10日払いサイクル)
--         -> period_type='MONTHLY', period_start_day=16 (前月16日〜当月15日を集計)
--   ID 2: 三井住友カード(NL) 100万円修行
--         1,000,000円につき 10,000pt。
--         period_type='YEARLY'、max_times_per_period=1 (年1回のみ)
--   ID 3: ヨドバシカメラ ポイントカード (100円で10pt、取引ごとの計算)
--         -> period_type='TRANSACTION'
--   ID 4: Vポイントカード提示 (200円で1pt、取引ごとの計算)
--         -> period_type='TRANSACTION'

INSERT INTO m_reward_rules (
	id, name, target_wallet_id, 
	unit_amount, grant_amount, 
	period_type, period_start_day, max_times_per_period
) VALUES 
-- クレジットカード利用、Vポイント還元（月間累計）
(1, '三井住友カードで支払い 0.5%還元', 6, 200, 1, 'MONTHLY', 16, NULL),
(2, '三井住友カードで支払い 100万円修行', 6, 1000000, 10000, 'YEARLY', 1, 1),
-- 家電量販店ポイント ヨドバシゴールドポイント還元（即時・取引毎）
(3, 'ヨドバシ カード提示 10%還元', 5, 100, 10, 'TRANSACTION', NULL, NULL),
-- 共通ポイントカード提示（即時・取引毎）
(4, 'Tポイントカード提示 0.5%還元', 6, 200, 1, 'TRANSACTION', NULL, NULL);

-- 2. 還元対象財布リスト (m_reward_source_wallets)
--   どの財布から支払った時に、どのルールが適用可能かを定義する。

INSERT INTO m_reward_source_wallets (rule_id, source_wallet_id) VALUES
-- Rule 1,2 (クレカ還元) は「メイン銀行口座(ID:2)」からの支払いで発生（デビット的運用のため）
(1, 2),
(2, 2),

-- Rule 3 (ヨドバシ) は「携帯用財布(現金 ID:1)」と「メイン銀行口座(ID:2)」からの支払いで発生
(3, 1),
(3, 2),

-- Rule 4 (Tポイントカード提示) は「携帯用財布(現金 ID:1)」と「メイン銀行口座(ID:2)」からの支払いで発生
(4, 1),
(4, 2);

-- 3. 還元権利行使ログ（資金移動に紐づく配列）

-- データ無しとする	
