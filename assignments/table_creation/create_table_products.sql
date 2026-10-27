create table products(
product_id int identity(1,1),
name varchar(100),
description varchar(max),
price decimal(12,2),
in_stock bit,
release_date date
);
