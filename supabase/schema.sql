-- =============================================
-- SISTEMA DE AGENDAMENTO DE BARBEARIA - SUPABASE
-- Executar no SQL Editor do Supabase
-- =============================================

-- =============================================
-- TABELA: barbeiros
-- =============================================
CREATE TABLE IF NOT EXISTS barbeiros (
    id        BIGSERIAL PRIMARY KEY,
    nome      TEXT NOT NULL,
    email     TEXT NOT NULL UNIQUE,
    telefone  TEXT,
    ativo     BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================
-- TABELA: servicos
-- =============================================
CREATE TABLE IF NOT EXISTS servicos (
    id               BIGSERIAL PRIMARY KEY,
    nome             TEXT NOT NULL UNIQUE,
    preco            NUMERIC(10, 2) NOT NULL CHECK (preco >= 0),
    duracao_minutos  INTEGER NOT NULL CHECK (duracao_minutos > 0),
    ativo            BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================
-- TABELA: agendamentos
-- =============================================
CREATE TABLE IF NOT EXISTS agendamentos (
    id                BIGSERIAL PRIMARY KEY,
    cliente_nome      TEXT NOT NULL,
    cliente_whatsapp  TEXT,
    barbeiro_id       BIGINT NOT NULL,
    servico_id        BIGINT NOT NULL,
    data_hora         TIMESTAMPTZ NOT NULL,
    status            TEXT NOT NULL DEFAULT 'pendente'
                      CHECK (status IN ('pendente', 'confirmado', 'concluido', 'cancelado')),
    criado_em         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Relacionamentos (FOREIGN KEYS)
    CONSTRAINT fk_agendamento_barbeiro
        FOREIGN KEY (barbeiro_id)
        REFERENCES barbeiros (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,

    CONSTRAINT fk_agendamento_servico
        FOREIGN KEY (servico_id)
        REFERENCES servicos (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
);

-- =============================================
-- ÍNDICES para consultas frequentes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_agendamentos_barbeiro
    ON agendamentos (barbeiro_id);

CREATE INDEX IF NOT EXISTS idx_agendamentos_servico
    ON agendamentos (servico_id);

CREATE INDEX IF NOT EXISTS idx_agendamentos_data_hora
    ON agendamentos (data_hora);

CREATE INDEX IF NOT EXISTS idx_agendamentos_status
    ON agendamentos (status);

-- =============================================
-- SEED: 2 barbeiros de exemplo
-- =============================================
INSERT INTO barbeiros (nome, email, telefone) VALUES
    ('Carlos Silva', 'carlos@barbearia.com.br', '(41) 99999-0001'),
    ('João Pereira', 'joao@barbearia.com.br', '(41) 99999-0002');

-- =============================================
-- SEED: 3 serviços de exemplo
-- =============================================
INSERT INTO servicos (nome, preco, duracao_minutos) VALUES
    ('Corte de Cabelo',     45.00, 45),
    ('Barba',                35.00, 30),
    ('Corte + Barba',       75.00, 75);

-- =============================================
-- NOTA: habilite o Row Level Security (RLS)
-- conforme as regras de acesso do seu app.
-- =============================================