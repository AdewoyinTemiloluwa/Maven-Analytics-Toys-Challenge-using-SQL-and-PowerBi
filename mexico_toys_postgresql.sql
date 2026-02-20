-- 1. Create Tables

CREATE TABLE Products (
  Product_ID INT PRIMARY KEY,
  Product_Name VARCHAR(100),
  Product_Category VARCHAR(50),
  Product_Cost NUMERIC(10,2),
  Product_Price NUMERIC(10,2)
);

CREATE TABLE stores (
  store_id       INT PRIMARY KEY,
  store_name     VARCHAR(200),
  store_city     VARCHAR(100),
  store_location VARCHAR(200),
  store_open_date DATE
);

CREATE TABLE inventory (
  store_id       INT NOT NULL,
  product_id     INT NOT NULL,
  stock_on_hand  INT DEFAULT 0,
  PRIMARY KEY (store_id, product_id),
  FOREIGN KEY (store_id) REFERENCES stores(store_id),
  FOREIGN KEY (product_id) REFERENCES products(product_id)
);

CREATE TABLE calendar (
  date DATE PRIMARY KEY);

CREATE TABLE sales (
  sale_id   BIGINT PRIMARY KEY,   -- use BIGINT if many rows
  date      DATE NOT NULL,
  store_id  INT NOT NULL,
  product_id INT NOT NULL,
  units     INT NOT NULL,
  FOREIGN KEY (store_id) REFERENCES stores(store_id),
  FOREIGN KEY (product_id) REFERENCES products(product_id)
);



-- 2. Data Validation & Cleaning
-- Check data consistency after import:

-- a. Missing mandatory fields
SELECT * FROM products WHERE product_name IS NULL OR product_cost IS NULL OR product_price IS NULL;
SELECT * FROM stores WHERE store_name IS NULL OR store_city IS NULL;
SELECT * FROM sales WHERE units IS NULL OR date IS NULL;
SELECT * FROM inventory WHERE stock_on_hand IS NULL;

-- b. Duplicates
SELECT product_id, COUNT(*) FROM products GROUP BY product_id HAVING COUNT(*) > 1;
SELECT sale_id, COUNT(*) FROM sales GROUP BY sale_id HAVING COUNT(*) > 1;
SELECT store_id, product_id, COUNT(*) FROM inventory GROUP BY store_id, product_id HAVING COUNT(*) > 1;

-- c. Orphan sales (no matching product or store)
SELECT s.* FROM sales s
LEFT JOIN products p ON s.product_id = p.product_id
WHERE p.product_id IS NULL;

SELECT s.* FROM sales s
LEFT JOIN stores st ON s.store_id = st.store_id
WHERE st.store_id IS NULL;

-- d. Inventory referencing non-existing entries
SELECT i.*
FROM inventory i
LEFT JOIN products p ON i.product_id = p.product_id
LEFT JOIN stores st ON i.store_id = st.store_id
WHERE p.product_id IS NULL OR st.store_id IS NULL;

-- e. Date range sanity
SELECT MIN(date), MAX(date) FROM sales;
SELECT MIN(date), MAX(date) FROM calendar;


-- 2. Enrich calendar table

-- Example: create calendar from min to max date in sales
INSERT INTO calendar(date)
SELECT generate_series(min(date), max(date), '1 day'::interval)::date
FROM sales
ON CONFLICT DO NOTHING;


-- Add columns for weekday, month, year, fiscal period:

ALTER TABLE calendar
  ADD COLUMN day_of_week VARCHAR(10),
  ADD COLUMN month INT,
  ADD COLUMN month_name VARCHAR(15),
  ADD COLUMN year INT,
  ADD COLUMN is_weekend BOOLEAN;

UPDATE calendar
SET day_of_week = to_char(date, 'Day'),
    month = EXTRACT(MONTH FROM date),
    month_name = to_char(date, 'FMMonth'),
    year = EXTRACT(YEAR FROM date),
    is_weekend = EXTRACT(ISODOW FROM date) IN (6,7);



-- ANALYSIS QUERIES
-- a. Top 20 Products by Units Sold
SELECT 
    p.product_id,
	st.store_name,
    p.product_name,
    SUM(s.units) AS total_units_sold
FROM sales s
JOIN products p ON s.product_id = p.product_id
JOIN stores st ON s.store_id = st.store_id
GROUP BY p.product_id, p.product_name, st.store_name
ORDER BY total_units_sold DESC
LIMIT 20;


-- b. Top 10 Products per Store 
WITH store_product_sales AS (
    SELECT 
        s.store_id,
        p.product_id,
        p.product_name,
        SUM(s.units) AS total_units
    FROM sales s
    JOIN products p ON s.product_id = p.product_id
    GROUP BY s.store_id, p.product_id, p.product_name
)
SELECT store_id, product_id, product_name, total_units
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY total_units DESC) AS rank_in_store
    FROM store_product_sales
) ranked
WHERE rank_in_store <= 10
ORDER BY store_id, total_units DESC;


-- c. Inventory vs. Sales Velocity
WITH sales_summary AS (
    SELECT 
        s.store_id,
        s.product_id,
        SUM(s.units) AS total_units_sold
    FROM sales s
    GROUP BY s.store_id, s.product_id
)
SELECT 
    st.store_name,
    p.product_name,
    i.stock_on_hand,
    COALESCE(ss.total_units_sold, 0) AS total_units_sold,
    CASE 
        WHEN COALESCE(ss.total_units_sold, 0) = 0 THEN NULL
        ELSE ROUND(i.stock_on_hand::numeric / ss.total_units_sold, 2)
    END AS stock_to_sales_ratio
FROM inventory i
JOIN stores st ON i.store_id = st.store_id
JOIN products p ON i.product_id = p.product_id
LEFT JOIN sales_summary ss ON ss.store_id = i.store_id AND ss.product_id = i.product_id
ORDER BY stock_to_sales_ratio NULLS LAST, total_units_sold DESC;


-- d. Product Profitability (Company-Wide)
SELECT 
    p.product_id,
    p.product_name,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * p.product_cost)::numeric, 2) AS total_cost,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    ROUND(
        (SUM(s.units * (p.product_price - p.product_cost)) / NULLIF(SUM(s.units * p.product_price), 0) * 100)::numeric, 2
    ) AS profit_margin_pct
FROM sales s
JOIN products p ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY total_profit DESC;

-- e. City-Level Performance Summary
SELECT 
    st.store_city,
    COUNT(DISTINCT st.store_id) AS number_of_stores,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit
FROM sales s
JOIN products p ON s.product_id = p.product_id
JOIN stores st ON s.store_id = st.store_id
GROUP BY st.store_city
ORDER BY total_revenue DESC;

-- f. — Store Performance Overview
SELECT 
    st.store_id,
    st.store_name,
    st.store_city,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    ROUND(
        (SUM(s.units * (p.product_price - p.product_cost)) / NULLIF(SUM(s.units * p.product_price), 0) * 100)::numeric, 2
    ) AS profit_margin_pct
FROM sales s
JOIN products p ON s.product_id = p.product_id
JOIN stores st ON s.store_id = st.store_id
GROUP BY st.store_id, st.store_name, st.store_city
ORDER BY total_profit DESC;

-- g. Product Category Analysis
SELECT 
    p.product_category,
    COUNT(DISTINCT p.product_id) AS num_products,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    ROUND(
        (SUM(s.units * (p.product_price - p.product_cost)) / NULLIF(SUM(s.units * p.product_price), 0) * 100)::numeric, 2
    ) AS avg_margin_pct
FROM sales s
JOIN products p ON s.product_id = p.product_id
GROUP BY p.product_category
ORDER BY total_profit DESC;

-- h. ABC Classification (All-Time)
WITH sales_rank AS (
  SELECT 
    p.product_id,
    p.product_name,
    SUM(s.units) AS units_sold
  FROM sales s
  JOIN products p ON s.product_id = p.product_id
  GROUP BY p.product_id, p.product_name
),
totals AS (
  SELECT SUM(units_sold) AS total_units FROM sales_rank
),
ranked AS (
  SELECT 
    sr.*,
    SUM(sr.units_sold) OVER (ORDER BY sr.units_sold DESC) AS running_units
  FROM sales_rank sr
)
SELECT 
    product_id,
    product_name,
    units_sold,
    (running_units * 100.0 / (SELECT total_units FROM totals))::numeric(5,2) AS running_pct,
    CASE 
        WHEN (running_units * 100.0 / (SELECT total_units FROM totals)) <= 50 THEN 'A'
        WHEN (running_units * 100.0 / (SELECT total_units FROM totals)) <= 80 THEN 'B'
        ELSE 'C'
    END AS abc_class
FROM ranked
ORDER BY units_sold DESC;

-- i. Stockout Risk (Low Stock vs. High Demand)
WITH sales_summary AS (
    SELECT 
        product_id, 
        SUM(units)::numeric AS total_units_sold
    FROM sales
    GROUP BY product_id
),
avg_stock AS (
    SELECT 
        product_id, 
        AVG(stock_on_hand)::numeric AS avg_stock
    FROM inventory
    GROUP BY product_id
)
SELECT 
    p.product_id,
    p.product_name,
    ROUND(COALESCE(a.avg_stock, 0), 2) AS avg_stock,
    ROUND(COALESCE(s.total_units_sold, 0), 2) AS total_units_sold,
    ROUND(
        (COALESCE(a.avg_stock, 0)::numeric / NULLIF(s.total_units_sold, 0)::numeric), 
        4
    ) AS stock_to_sales_ratio
FROM sales_summary s
JOIN products p 
    ON s.product_id = p.product_id
LEFT JOIN avg_stock a 
    ON a.product_id = p.product_id
WHERE s.total_units_sold > 0
ORDER BY stock_to_sales_ratio ASC
LIMIT 20;


-- i. Company-Wide KPIs
SELECT 
    COUNT(DISTINCT s.store_id) AS total_stores,
    COUNT(DISTINCT p.product_id) AS total_products,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    ROUND((SUM(s.units * (p.product_price - p.product_cost)) / NULLIF(SUM(s.units * p.product_price), 0) * 100)::numeric, 2) AS overall_margin_pct
FROM sales s
JOIN products p ON s.product_id = p.product_id;


-- j. Yearly Sales Performance per Store
SELECT 
    st.store_id,
    st.store_name,
    EXTRACT(YEAR FROM s.date) AS year,
    SUM(s.units) AS total_units_sold,
    ROUND(SUM(s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND(SUM(s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    STRING_AGG(DISTINCT p.product_name, ', ') AS top_products
FROM sales s
JOIN products p 
    ON s.product_id = p.product_id
JOIN stores st 
    ON s.store_id = st.store_id
GROUP BY st.store_id, st.store_name, EXTRACT(YEAR FROM s.date)
ORDER BY total_revenue DESC, total_profit DESC, total_units_sold DESC;



CREATE VIEW retail_analysis_view AS
SELECT 
    s.sale_id,
    s.date,
    s.store_id,
    st.store_name,
    st.store_city,
    st.store_location,
    p.product_id,
    p.product_name,
    p.product_category,
    p.product_cost,
    p.product_price,
    s.units,
    i.stock_on_hand,
    ROUND((s.units * p.product_price)::numeric, 2) AS total_revenue,
    ROUND((s.units * (p.product_price - p.product_cost))::numeric, 2) AS total_profit,
    ROUND(
        CASE 
            WHEN (s.units * p.product_price) = 0 THEN 0
            ELSE ((s.units * (p.product_price - p.product_cost)) / (s.units * p.product_price)) * 100
        END, 
        2
    ) AS profit_margin_percent
FROM sales s
JOIN products p 
    ON s.product_id = p.product_id
JOIN stores st 
    ON s.store_id = st.store_id
LEFT JOIN inventory i 
    ON s.product_id = i.product_id
    AND s.store_id = i.store_id
ORDER BY s.date ASC;