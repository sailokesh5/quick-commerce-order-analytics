-- ============================================================
-- Schema for a fictional quick-commerce company.
-- Run ONLY against the qcommerce_v2 database.
-- Running this file wipes and rebuilds every table.
-- ============================================================
DROP VIEW  IF EXISTS city_dim;
DROP TABLE IF EXISTS session_events, orders, sessions, users, cities CASCADE;

-- Cities and store counts: copied from a published city-wise store-count list
-- (qcommerceguide.com, published 14 Aug 2026, accessed 9 Oct 2026), treated as
-- approximate. The fictional company's network is modeled on that list.
-- hra_class: government HRA city class (X/Y/Z), population-based. No single
-- official "tier" list exists; HRA is the closest official standard.
-- The source for each city's class is recorded in docs/sources.md.
CREATE TABLE cities (
    city_id     SERIAL PRIMARY KEY,
    city_name   VARCHAR(30) NOT NULL UNIQUE,
    store_count INT NOT NULL CHECK (store_count > 0),
    hra_class   CHAR(1) NOT NULL CHECK (hra_class IN ('X','Y','Z'))
);

INSERT INTO cities (city_name, store_count, hra_class) VALUES
('Delhi',171,'X'), ('Bangalore',165,'X'), ('Hyderabad',94,'X'), ('Pune',84,'X'),
('Mumbai',83,'X'), ('Gurgaon',75,'Y'), ('Chennai',62,'X'), ('Kolkata',58,'X'),
('Lucknow',49,'Y'), ('Ahmedabad',44,'X'), ('Ghaziabad',38,'Y'), ('Jaipur',38,'Y'),
('Noida',33,'Y'), ('Patna',22,'Y'), ('Faridabad',22,'Y'), ('Thane',21,'X'),
('Bhopal',20,'Y'), ('Kanpur',19,'Y'), ('Navi Mumbai',18,'X'), ('Nagpur',17,'Y');

-- Derived in a view so it can never go stale. Band cutoffs are my own choice.
CREATE VIEW city_dim AS
SELECT city_id, city_name, store_count, hra_class,
       CASE WHEN store_count >= 75 THEN 'Large'
            WHEN store_count >= 40 THEN 'Mid'
            ELSE 'Small' END AS store_band
FROM cities;

CREATE TABLE users (
    user_id        SERIAL PRIMARY KEY,
    signup_date    DATE NOT NULL,
    home_city_id   INT NOT NULL REFERENCES cities(city_id),
    signup_channel VARCHAR(20) NOT NULL
                   CHECK (signup_channel IN ('organic','referral','paid_ad','social'))
);

CREATE TABLE sessions (
    session_id    SERIAL PRIMARY KEY,
    user_id       INT NOT NULL REFERENCES users(user_id),
    city_id       INT NOT NULL REFERENCES cities(city_id),
    session_start TIMESTAMP NOT NULL,
    platform      VARCHAR(10) NOT NULL CHECK (platform IN ('android','ios','web'))
);

CREATE TABLE session_events (
    event_id   BIGSERIAL PRIMARY KEY,
    session_id INT NOT NULL REFERENCES sessions(session_id),
    stage      VARCHAR(20) NOT NULL CHECK (stage IN
               ('app_open','browse','product_view','add_to_cart',
                'checkout_start','payment_attempt','order_placed')),
    event_time TIMESTAMP NOT NULL,
    UNIQUE (session_id, stage)
);

CREATE TABLE orders (
    order_id             SERIAL PRIMARY KEY,
    session_id           INT NOT NULL UNIQUE REFERENCES sessions(session_id),
    user_id              INT NOT NULL REFERENCES users(user_id),
    city_id              INT NOT NULL REFERENCES cities(city_id),
    order_placed_time    TIMESTAMP NOT NULL,
    order_delivered_time TIMESTAMP,
    order_amount         NUMERIC(8,2) NOT NULL CHECK (order_amount > 0),
    order_status         VARCHAR(20) NOT NULL CHECK (order_status IN ('delivered','cancelled')),
    cancellation_reason  VARCHAR(40) CHECK (cancellation_reason IS NULL OR cancellation_reason IN
                         ('out_of_stock','long_wait_time','changed_plans','delivery_partner_issue')),
    CHECK ( (order_status = 'delivered' AND order_delivered_time IS NOT NULL AND cancellation_reason IS NULL)
         OR (order_status = 'cancelled' AND order_delivered_time IS NULL AND cancellation_reason IS NOT NULL) )
);

CREATE INDEX idx_sessions_city  ON sessions(city_id);
CREATE INDEX idx_sessions_start ON sessions(session_start);
CREATE INDEX idx_orders_city    ON orders(city_id);
CREATE INDEX idx_orders_placed  ON orders(order_placed_time);