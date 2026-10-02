--
-- PostgreSQL database dump
--

\restrict ucHBaSTpCzrdXh8ydLhcIxPXxhnBa0TPvDdebQeIXBiQIAoZ2iz4lKxxrsiRdjh

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: pluggy_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO public.pluggy_items VALUES ('b8e8a67d-7fab-436f-b956-4545ba6b783e', '4f8078fa-b126-4bc9-9eff-5d293b834721', 'Banco do Brasil', '2026-08-02 13:57:31', '2026-08-02 13:57:31');
INSERT INTO public.pluggy_items VALUES ('ad385e9f-1c41-42f8-8e26-939cfdc08f01', '56f06fe6-cd3e-41dc-9ecb-e1032ed77dfd', 'Bradesco', '2026-08-02 13:57:46', '2026-08-02 13:57:46');
INSERT INTO public.pluggy_items VALUES ('8f142121-bac5-4050-aff6-006536fcb1bb', '48e81937-84ac-4a1a-812c-720d17d6d3aa', 'Mercado Pago', '2026-08-02 13:58:08', '2026-08-02 13:58:08');


--
-- Data for Name: pluggy_account_links; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO public.pluggy_account_links VALUES ('b525cf87-df77-4656-8ff0-86ba86f42e2c', 'ad385e9f-1c41-42f8-8e26-939cfdc08f01', 'bf6d7f9e-9924-41cc-86bc-a93729d38bbb', 'Banco Bradesco', 'BANK', NULL, NULL, '2026-08-02 13:58:49', '2026-08-02 14:08:28', 0);
INSERT INTO public.pluggy_account_links VALUES ('f82aae91-b33f-445f-a0f3-21bac4fea78e', 'b8e8a67d-7fab-436f-b956-4545ba6b783e', '7bd26f9e-b44c-4db0-9719-df3dd30012be', 'BANCO DO BRASIL S/A', 'BANK', NULL, NULL, '2026-08-02 13:57:39', '2026-08-27 12:58:02', 282.92);
INSERT INTO public.pluggy_account_links VALUES ('a395e282-f078-4f1b-8164-c61e21c346dd', '8f142121-bac5-4050-aff6-006536fcb1bb', 'cefcd6c6-bd48-400c-be79-99ee59af5b0b', 'Mercado Pago', 'CREDIT', 'de7aab37-2011-42d2-a2e7-5e21c6a5e0b7', NULL, '2026-08-02 14:07:36', '2026-09-15 17:15:01', 4133.42);
INSERT INTO public.pluggy_account_links VALUES ('6392b443-4937-4bff-82e8-35a9be4f8d78', '8f142121-bac5-4050-aff6-006536fcb1bb', 'af520ca8-def3-4f65-9f44-814ddd779559', 'Mercado Pago', 'BANK', '76d9f12b-01f2-47c3-a3c4-33e30131d671', NULL, '2026-08-02 14:07:36', '2026-09-21 16:35:17', 91.31);
INSERT INTO public.pluggy_account_links VALUES ('3753d0ce-4d80-4063-83dd-199a1e89d296', 'ad385e9f-1c41-42f8-8e26-939cfdc08f01', 'cca5af0d-c52e-4f59-8937-0cd67e19876a', 'AMERICAN EXPRESS GOLD CARD PRI', 'CREDIT', 'd78434a3-8c9e-4138-8419-d0bf5549dbb7', NULL, '2026-08-02 13:58:49', '2026-09-21 16:35:17', 2665.75);
INSERT INTO public.pluggy_account_links VALUES ('9a03f013-4074-466c-96cf-db41b6a07f9b', 'b8e8a67d-7fab-436f-b956-4545ba6b783e', '6a416344-feff-4b1a-bd29-8155f801c01e', 'BANCO DO BRASIL S/A', 'BANK', '9e48e18f-e96f-4767-a747-de5928217183', NULL, '2026-08-02 13:57:39', '2026-09-21 16:35:17', 26203.47);
INSERT INTO public.pluggy_account_links VALUES ('5aa4761a-a6fe-4a19-96d0-2a83514af0b8', 'b8e8a67d-7fab-436f-b956-4545ba6b783e', '8d8bd60a-3b6c-47b8-9f17-6b87be7ef210', 'OUROCARD INFINITE VISA ESTILO', 'CREDIT', '53f9f28c-be0c-4484-b272-a75db1fefc29', NULL, '2026-08-02 13:57:39', '2026-09-21 21:37:53', 22362);
INSERT INTO public.pluggy_account_links VALUES ('1154cd79-4442-4933-969f-2e1f5f49d149', 'ad385e9f-1c41-42f8-8e26-939cfdc08f01', 'd076a96d-680f-470d-baa6-7a802d2b1ded', 'Banco Bradesco', 'BANK', '6d0f41ab-4500-4982-b52e-579a43a33264', NULL, '2026-08-02 13:58:49', '2026-09-21 22:07:53', 141.67);


--
-- PostgreSQL database dump complete
--

\unrestrict ucHBaSTpCzrdXh8ydLhcIxPXxhnBa0TPvDdebQeIXBiQIAoZ2iz4lKxxrsiRdjh

--
-- PostgreSQL database dump
--

\restrict 3FuSicE9i8xt61G9r3ta9a4J7Toks0UvbdQjEbWtWC1SZsPvAhMfSuib2NP1xOP

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: pluggy_account_links; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pluggy_account_links (
    id uuid NOT NULL,
    pluggy_item_id uuid NOT NULL,
    pluggy_account_id character varying(255) NOT NULL,
    pluggy_account_name character varying(255),
    pluggy_account_type character varying(255),
    account_id uuid,
    last_synced_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    pluggy_balance numeric
);


ALTER TABLE public.pluggy_account_links OWNER TO postgres;

--
-- Name: pluggy_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pluggy_items (
    id uuid NOT NULL,
    item_id character varying(255) NOT NULL,
    label character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


ALTER TABLE public.pluggy_items OWNER TO postgres;

--
-- Name: pluggy_account_links pluggy_account_links_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pluggy_account_links
    ADD CONSTRAINT pluggy_account_links_pkey PRIMARY KEY (id);


--
-- Name: pluggy_items pluggy_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pluggy_items
    ADD CONSTRAINT pluggy_items_pkey PRIMARY KEY (id);


--
-- Name: pluggy_account_links_account_id_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX pluggy_account_links_account_id_index ON public.pluggy_account_links USING btree (account_id);


--
-- Name: pluggy_account_links_pluggy_item_id_pluggy_account_id_index; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX pluggy_account_links_pluggy_item_id_pluggy_account_id_index ON public.pluggy_account_links USING btree (pluggy_item_id, pluggy_account_id);


--
-- Name: pluggy_account_links pluggy_account_links_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pluggy_account_links
    ADD CONSTRAINT pluggy_account_links_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE SET NULL;


--
-- Name: pluggy_account_links pluggy_account_links_pluggy_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pluggy_account_links
    ADD CONSTRAINT pluggy_account_links_pluggy_item_id_fkey FOREIGN KEY (pluggy_item_id) REFERENCES public.pluggy_items(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 3FuSicE9i8xt61G9r3ta9a4J7Toks0UvbdQjEbWtWC1SZsPvAhMfSuib2NP1xOP

