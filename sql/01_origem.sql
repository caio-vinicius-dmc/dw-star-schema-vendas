-- Base transacional simulada. É a "origem" do data warehouse: normalizada,
-- com chaves próprias e sem nenhuma preocupação analítica -- exatamente o
-- que o time de dados costuma receber de um sistema de vendas.

CREATE SCHEMA IF NOT EXISTS origem;

DROP TABLE IF EXISTS origem.item_pedido CASCADE;
DROP TABLE IF EXISTS origem.pedido CASCADE;
DROP TABLE IF EXISTS origem.produto CASCADE;
DROP TABLE IF EXISTS origem.cliente CASCADE;
DROP TABLE IF EXISTS origem.loja CASCADE;

CREATE TABLE origem.cliente (
    id            integer PRIMARY KEY,
    nome          text        NOT NULL,
    cidade        text        NOT NULL,
    uf            char(2)     NOT NULL,
    -- Segmento e cidade mudam com o tempo. São justamente os atributos que
    -- justificam versionar a dimensão de cliente (SCD tipo 2).
    segmento      text        NOT NULL,
    cadastrado_em date        NOT NULL,
    atualizado_em timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE origem.produto (
    id           integer PRIMARY KEY,
    sku          text UNIQUE   NOT NULL,
    nome         text          NOT NULL,
    categoria    text          NOT NULL,
    subcategoria text          NOT NULL,
    marca        text          NOT NULL,
    preco_lista  numeric(10,2) NOT NULL,
    custo        numeric(10,2) NOT NULL
);

CREATE TABLE origem.loja (
    id      integer PRIMARY KEY,
    codigo  text UNIQUE NOT NULL,
    nome    text        NOT NULL,
    cidade  text        NOT NULL,
    uf      char(2)     NOT NULL,
    regiao  text        NOT NULL,
    tipo    text        NOT NULL   -- física ou online
);

CREATE TABLE origem.pedido (
    id         integer PRIMARY KEY,
    cliente_id integer     NOT NULL REFERENCES origem.cliente (id),
    loja_id    integer     NOT NULL REFERENCES origem.loja (id),
    criado_em  timestamptz NOT NULL,
    status     text        NOT NULL
);

CREATE TABLE origem.item_pedido (
    id             bigint PRIMARY KEY,
    pedido_id      integer       NOT NULL REFERENCES origem.pedido (id),
    produto_id     integer       NOT NULL REFERENCES origem.produto (id),
    numero_item    smallint      NOT NULL,
    quantidade     smallint      NOT NULL,
    preco_unitario numeric(10,2) NOT NULL,
    desconto       numeric(10,2) NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_pedido_data ON origem.pedido (criado_em);
CREATE INDEX IF NOT EXISTS idx_item_pedido ON origem.item_pedido (pedido_id);
