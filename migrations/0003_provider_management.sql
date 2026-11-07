-- Sticky marker: deleting the final provider must not reactivate env credentials.
CREATE TABLE provider_management (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton));
INSERT INTO provider_management SELECT true WHERE EXISTS (SELECT 1 FROM providers);
