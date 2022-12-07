CREATE TABLE article (
  id integer primary key,
  title varchar(255),
  created_at timestamp not null
);

INSERT INTO article (id, title, created_at) VALUES (
  1, 'hello', now()
);
INSERT INTO article (id, title, created_at) VALUES (
  2, 'initialized!', now()
);
