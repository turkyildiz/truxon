export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      activity_log: {
        Row: {
          action: string
          created_at: string
          detail: string
          entity_id: number
          entity_type: string
          id: number
          user_id: string | null
        }
        Insert: {
          action: string
          created_at?: string
          detail?: string
          entity_id: number
          entity_type: string
          id?: never
          user_id?: string | null
        }
        Update: {
          action?: string
          created_at?: string
          detail?: string
          entity_id?: number
          entity_type?: string
          id?: never
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "activity_log_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_corrections: {
        Row: {
          corrected_by: string | null
          created_at: string
          entity_id: number
          entity_type: string
          field: string
          human_value: string
          id: number
          model: string | null
          model_value: string
        }
        Insert: {
          corrected_by?: string | null
          created_at?: string
          entity_id: number
          entity_type?: string
          field: string
          human_value: string
          id?: never
          model?: string | null
          model_value: string
        }
        Update: {
          corrected_by?: string | null
          created_at?: string
          entity_id?: number
          entity_type?: string
          field?: string
          human_value?: string
          id?: never
          model?: string | null
          model_value?: string
        }
        Relationships: []
      }
      bs_snapshot: {
        Row: {
          ap: number | null
          ar: number | null
          as_of: string
          cash: number | null
          current_assets: number | null
          current_liabilities: number | null
          equity: number | null
          total_assets: number | null
          total_liabilities: number | null
          updated_at: string
        }
        Insert: {
          ap?: number | null
          ar?: number | null
          as_of: string
          cash?: number | null
          current_assets?: number | null
          current_liabilities?: number | null
          equity?: number | null
          total_assets?: number | null
          total_liabilities?: number | null
          updated_at?: string
        }
        Update: {
          ap?: number | null
          ar?: number | null
          as_of?: string
          cash?: number | null
          current_assets?: number | null
          current_liabilities?: number | null
          equity?: number | null
          total_assets?: number | null
          total_liabilities?: number | null
          updated_at?: string
        }
        Relationships: []
      }
      budgets: {
        Row: {
          amount: number
          id: number
          line: string
          period_month: string
          updated_at: string
        }
        Insert: {
          amount?: number
          id?: never
          line: string
          period_month: string
          updated_at?: string
        }
        Update: {
          amount?: number
          id?: never
          line?: string
          period_month?: string
          updated_at?: string
        }
        Relationships: []
      }
      carrier_safety_snapshot: {
        Row: {
          allowed_to_operate: string
          captured_at: string
          crash_total: number | null
          dot_number: string
          driver_insp: number | null
          driver_oos_insp: number | null
          driver_oos_natl: number | null
          driver_oos_rate: number | null
          fatal_crash: number | null
          id: number
          inj_crash: number | null
          iss_score: number | null
          legal_name: string
          mcs150_outdated: boolean | null
          oos_date: string | null
          raw: Json | null
          review_date: string | null
          safety_rating: string
          safety_rating_date: string | null
          snapshot_date: string
          status_code: string
          total_drivers: number | null
          total_power_units: number | null
          towaway_crash: number | null
          vehicle_insp: number | null
          vehicle_oos_insp: number | null
          vehicle_oos_natl: number | null
          vehicle_oos_rate: number | null
        }
        Insert: {
          allowed_to_operate?: string
          captured_at?: string
          crash_total?: number | null
          dot_number?: string
          driver_insp?: number | null
          driver_oos_insp?: number | null
          driver_oos_natl?: number | null
          driver_oos_rate?: number | null
          fatal_crash?: number | null
          id?: never
          inj_crash?: number | null
          iss_score?: number | null
          legal_name?: string
          mcs150_outdated?: boolean | null
          oos_date?: string | null
          raw?: Json | null
          review_date?: string | null
          safety_rating?: string
          safety_rating_date?: string | null
          snapshot_date: string
          status_code?: string
          total_drivers?: number | null
          total_power_units?: number | null
          towaway_crash?: number | null
          vehicle_insp?: number | null
          vehicle_oos_insp?: number | null
          vehicle_oos_natl?: number | null
          vehicle_oos_rate?: number | null
        }
        Update: {
          allowed_to_operate?: string
          captured_at?: string
          crash_total?: number | null
          dot_number?: string
          driver_insp?: number | null
          driver_oos_insp?: number | null
          driver_oos_natl?: number | null
          driver_oos_rate?: number | null
          fatal_crash?: number | null
          id?: never
          inj_crash?: number | null
          iss_score?: number | null
          legal_name?: string
          mcs150_outdated?: boolean | null
          oos_date?: string | null
          raw?: Json | null
          review_date?: string | null
          safety_rating?: string
          safety_rating_date?: string | null
          snapshot_date?: string
          status_code?: string
          total_drivers?: number | null
          total_power_units?: number | null
          towaway_crash?: number | null
          vehicle_insp?: number | null
          vehicle_oos_insp?: number | null
          vehicle_oos_natl?: number | null
          vehicle_oos_rate?: number | null
        }
        Relationships: []
      }
      companion_config: {
        Row: {
          flags: Json
          id: number
          updated_at: string
        }
        Insert: {
          flags?: Json
          id?: number
          updated_at?: string
        }
        Update: {
          flags?: Json
          id?: number
          updated_at?: string
        }
        Relationships: []
      }
      company_settings: {
        Row: {
          address: string
          company_name: string
          email: string
          id: number
          logo_path: string
          mc_number: string
          phone: string
          updated_at: string
          usdot_number: string
        }
        Insert: {
          address?: string
          company_name?: string
          email?: string
          id?: number
          logo_path?: string
          mc_number?: string
          phone?: string
          updated_at?: string
          usdot_number?: string
        }
        Update: {
          address?: string
          company_name?: string
          email?: string
          id?: number
          logo_path?: string
          mc_number?: string
          phone?: string
          updated_at?: string
          usdot_number?: string
        }
        Relationships: []
      }
      customer_enrichment_log: {
        Row: {
          created_at: string
          customer_id: number
          field: string
          id: number
          model: string | null
          new_value: string
          old_value: string | null
          source_document_id: number | null
        }
        Insert: {
          created_at?: string
          customer_id: number
          field: string
          id?: never
          model?: string | null
          new_value: string
          old_value?: string | null
          source_document_id?: number | null
        }
        Update: {
          created_at?: string
          customer_id?: number
          field?: string
          id?: never
          model?: string | null
          new_value?: string
          old_value?: string | null
          source_document_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_enrichment_log_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_enrichment_log_source_document_id_fkey"
            columns: ["source_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_qbo_aliases: {
        Row: {
          created_at: string
          customer_id: number
          qbo_id: string
        }
        Insert: {
          created_at?: string
          customer_id: number
          qbo_id: string
        }
        Update: {
          created_at?: string
          customer_id?: number
          qbo_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "customer_qbo_aliases_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customers: {
        Row: {
          billing_address: string
          company_name: string
          contact_person: string
          created_at: string
          do_not_use: boolean
          email: string
          enriched_at: string | null
          fax: string
          id: number
          is_active: boolean
          mc_number: string
          notes: string
          payment_terms: string
          phone: string
          qbo_id: string | null
          secondary_contact: string
          secondary_email: string
          secondary_phone: string
          toll_free: string
          updated_at: string
          usdot_number: string
        }
        Insert: {
          billing_address?: string
          company_name: string
          contact_person?: string
          created_at?: string
          do_not_use?: boolean
          email?: string
          enriched_at?: string | null
          fax?: string
          id?: never
          is_active?: boolean
          mc_number?: string
          notes?: string
          payment_terms?: string
          phone?: string
          qbo_id?: string | null
          secondary_contact?: string
          secondary_email?: string
          secondary_phone?: string
          toll_free?: string
          updated_at?: string
          usdot_number?: string
        }
        Update: {
          billing_address?: string
          company_name?: string
          contact_person?: string
          created_at?: string
          do_not_use?: boolean
          email?: string
          enriched_at?: string | null
          fax?: string
          id?: never
          is_active?: boolean
          mc_number?: string
          notes?: string
          payment_terms?: string
          phone?: string
          qbo_id?: string | null
          secondary_contact?: string
          secondary_email?: string
          secondary_phone?: string
          toll_free?: string
          updated_at?: string
          usdot_number?: string
        }
        Relationships: []
      }
      doc_search_requests: {
        Row: {
          claimed_at: string | null
          completed_at: string | null
          created_at: string
          entity_type: string | null
          error: string | null
          id: number
          query: string
          requester: string | null
          results: Json | null
          status: string
        }
        Insert: {
          claimed_at?: string | null
          completed_at?: string | null
          created_at?: string
          entity_type?: string | null
          error?: string | null
          id?: never
          query: string
          requester?: string | null
          results?: Json | null
          status?: string
        }
        Update: {
          claimed_at?: string | null
          completed_at?: string | null
          created_at?: string
          entity_type?: string | null
          error?: string | null
          id?: never
          query?: string
          requester?: string | null
          results?: Json | null
          status?: string
        }
        Relationships: []
      }
      document_embeddings: {
        Row: {
          chunk_index: number
          content: string
          created_at: string
          document_id: number | null
          drive_file_id: number | null
          embedding: string
          entity_id: number
          entity_type: string
          id: number
        }
        Insert: {
          chunk_index?: number
          content: string
          created_at?: string
          document_id?: number | null
          drive_file_id?: number | null
          embedding: string
          entity_id: number
          entity_type: string
          id?: never
        }
        Update: {
          chunk_index?: number
          content?: string
          created_at?: string
          document_id?: number | null
          drive_file_id?: number | null
          embedding?: string
          entity_id?: number
          entity_type?: string
          id?: never
        }
        Relationships: [
          {
            foreignKeyName: "document_embeddings_document_id_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "document_embeddings_drive_file_id_fkey"
            columns: ["drive_file_id"]
            isOneToOne: false
            referencedRelation: "drive_files"
            referencedColumns: ["id"]
          },
        ]
      }
      documents: {
        Row: {
          content_type: string
          doc_type: string
          entity_id: number
          entity_type: string
          filename: string
          id: number
          indexed_at: string | null
          size_bytes: number
          storage_path: string
          uploaded_at: string
          uploaded_by: string | null
        }
        Insert: {
          content_type?: string
          doc_type?: string
          entity_id: number
          entity_type: string
          filename: string
          id?: never
          indexed_at?: string | null
          size_bytes?: number
          storage_path: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Update: {
          content_type?: string
          doc_type?: string
          entity_id?: number
          entity_type?: string
          filename?: string
          id?: never
          indexed_at?: string | null
          size_bytes?: number
          storage_path?: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "documents_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      drive_files: {
        Row: {
          content_type: string
          drive: string
          filename: string
          folder: string
          id: number
          indexed_at: string | null
          is_folder: boolean
          owner_id: string
          parent: string
          size_bytes: number
          storage_path: string | null
          uploaded_at: string
        }
        Insert: {
          content_type?: string
          drive: string
          filename: string
          folder?: string
          id?: never
          indexed_at?: string | null
          is_folder?: boolean
          owner_id: string
          parent?: string
          size_bytes?: number
          storage_path?: string | null
          uploaded_at?: string
        }
        Update: {
          content_type?: string
          drive?: string
          filename?: string
          folder?: string
          id?: never
          indexed_at?: string | null
          is_folder?: boolean
          owner_id?: string
          parent?: string
          size_bytes?: number
          storage_path?: string | null
          uploaded_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "drive_files_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      drive_shares: {
        Row: {
          created_at: string
          created_by: string
          drive_file_id: number
          expires_at: string | null
          id: number
          revoked: boolean
          token: string
        }
        Insert: {
          created_at?: string
          created_by: string
          drive_file_id: number
          expires_at?: string | null
          id?: never
          revoked?: boolean
          token: string
        }
        Update: {
          created_at?: string
          created_by?: string
          drive_file_id?: number
          expires_at?: string | null
          id?: never
          revoked?: boolean
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "drive_shares_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "drive_shares_drive_file_id_fkey"
            columns: ["drive_file_id"]
            isOneToOne: false
            referencedRelation: "drive_files"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_duty: {
        Row: {
          driver_id: number
          is_on_duty: boolean
          on_duty_since: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          driver_id: number
          is_on_duty?: boolean
          on_duty_since?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          driver_id?: number
          is_on_duty?: boolean
          on_duty_since?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "driver_duty_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: true
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_duty_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      drivers: {
        Row: {
          address: string
          city: string
          created_at: string
          date_of_birth: string | null
          email: string
          empty_miles_paid: boolean
          full_name: string
          hire_date: string | null
          id: number
          license_expiration: string | null
          license_number: string
          notes: string
          pay_per_empty_mile: number
          pay_per_mile: number
          phone: string
          state: string
          status: Database["public"]["Enums"]["driver_status"]
          updated_at: string
          user_id: string | null
        }
        Insert: {
          address?: string
          city?: string
          created_at?: string
          date_of_birth?: string | null
          email?: string
          empty_miles_paid?: boolean
          full_name: string
          hire_date?: string | null
          id?: never
          license_expiration?: string | null
          license_number?: string
          notes?: string
          pay_per_empty_mile?: number
          pay_per_mile?: number
          phone?: string
          state?: string
          status?: Database["public"]["Enums"]["driver_status"]
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          address?: string
          city?: string
          created_at?: string
          date_of_birth?: string | null
          email?: string
          empty_miles_paid?: boolean
          full_name?: string
          hire_date?: string | null
          id?: never
          license_expiration?: string | null
          license_number?: string
          notes?: string
          pay_per_empty_mile?: number
          pay_per_mile?: number
          phone?: string
          state?: string
          status?: Database["public"]["Enums"]["driver_status"]
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "drivers_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      eld_driver_status: {
        Row: {
          break_sec: number | null
          current_status: string | null
          cycle_sec: number | null
          drive_sec: number | null
          driver_id: string
          shift_sec: number | null
          updated_at: string
          username: string | null
        }
        Insert: {
          break_sec?: number | null
          current_status?: string | null
          cycle_sec?: number | null
          drive_sec?: number | null
          driver_id: string
          shift_sec?: number | null
          updated_at?: string
          username?: string | null
        }
        Update: {
          break_sec?: number | null
          current_status?: string | null
          cycle_sec?: number | null
          drive_sec?: number | null
          driver_id?: string
          shift_sec?: number | null
          updated_at?: string
          username?: string | null
        }
        Relationships: []
      }
      eld_drivers: {
        Row: {
          active: boolean
          driver_id: string
          first_name: string
          last_name: string
          last_seen: string
          matched_driver_id: number | null
          raw: Json | null
          username: string
        }
        Insert: {
          active?: boolean
          driver_id: string
          first_name?: string
          last_name?: string
          last_seen?: string
          matched_driver_id?: number | null
          raw?: Json | null
          username?: string
        }
        Update: {
          active?: boolean
          driver_id?: string
          first_name?: string
          last_name?: string
          last_seen?: string
          matched_driver_id?: number | null
          raw?: Json | null
          username?: string
        }
        Relationships: [
          {
            foreignKeyName: "eld_drivers_matched_driver_id_fkey"
            columns: ["matched_driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
        ]
      }
      eld_location_history: {
        Row: {
          calc_location: string | null
          direction: number | null
          id: string
          lat: number | null
          lng: number | null
          speed: number | null
          status: string | null
          truck_id: number | null
          ts: string
          vehicle_id: string | null
          vehicle_number: string | null
          vin: string | null
        }
        Insert: {
          calc_location?: string | null
          direction?: number | null
          id: string
          lat?: number | null
          lng?: number | null
          speed?: number | null
          status?: string | null
          truck_id?: number | null
          ts: string
          vehicle_id?: string | null
          vehicle_number?: string | null
          vin?: string | null
        }
        Update: {
          calc_location?: string | null
          direction?: number | null
          id?: string
          lat?: number | null
          lng?: number | null
          speed?: number | null
          status?: string | null
          truck_id?: number | null
          ts?: string
          vehicle_id?: string | null
          vehicle_number?: string | null
          vin?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "eld_location_history_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      eld_vehicle_status: {
        Row: {
          calc_location: string | null
          eld_driver_id: string | null
          fuel_level: number | null
          lat: number | null
          lon: number | null
          number: string | null
          odometer: number | null
          speed: number | null
          status: string | null
          ts: string | null
          updated_at: string
          vehicle_id: string
          vin: string | null
        }
        Insert: {
          calc_location?: string | null
          eld_driver_id?: string | null
          fuel_level?: number | null
          lat?: number | null
          lon?: number | null
          number?: string | null
          odometer?: number | null
          speed?: number | null
          status?: string | null
          ts?: string | null
          updated_at?: string
          vehicle_id: string
          vin?: string | null
        }
        Update: {
          calc_location?: string | null
          eld_driver_id?: string | null
          fuel_level?: number | null
          lat?: number | null
          lon?: number | null
          number?: string | null
          odometer?: number | null
          speed?: number | null
          status?: string | null
          ts?: string | null
          updated_at?: string
          vehicle_id?: string
          vin?: string | null
        }
        Relationships: []
      }
      eld_vehicles: {
        Row: {
          active: boolean
          last_seen: string
          number: string
          raw: Json | null
          truck_id: number | null
          vehicle_id: string
          vin: string
        }
        Insert: {
          active?: boolean
          last_seen?: string
          number?: string
          raw?: Json | null
          truck_id?: number | null
          vehicle_id: string
          vin?: string
        }
        Update: {
          active?: boolean
          last_seen?: string
          number?: string
          raw?: Json | null
          truck_id?: number | null
          vehicle_id?: string
          vin?: string
        }
        Relationships: [
          {
            foreignKeyName: "eld_vehicles_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      equipment_enrichment_log: {
        Row: {
          action: string
          created_at: string
          equipment_id: number
          equipment_type: string
          field: string
          id: number
          model: string | null
          new_value: string
          old_value: string | null
          resolution: string | null
          resolved_at: string | null
          resolved_by: string | null
          source_document_id: number | null
        }
        Insert: {
          action: string
          created_at?: string
          equipment_id: number
          equipment_type: string
          field: string
          id?: never
          model?: string | null
          new_value: string
          old_value?: string | null
          resolution?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          source_document_id?: number | null
        }
        Update: {
          action?: string
          created_at?: string
          equipment_id?: number
          equipment_type?: string
          field?: string
          id?: never
          model?: string | null
          new_value?: string
          old_value?: string | null
          resolution?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          source_document_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "equipment_enrichment_log_source_document_id_fkey"
            columns: ["source_document_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id"]
          },
        ]
      }
      fuel_transactions: {
        Row: {
          amount: number
          card_last_four: string | null
          description: string
          discount: number | null
          driver_id: number | null
          driver_name: string
          fuel_type: string
          gallons: number | null
          id: number
          imported_at: string
          merchant: string
          merchant_category: string
          merchant_city: string
          merchant_state: string
          merchant_zip: string
          net_of_discount: number | null
          posted_date: string | null
          price_per_gallon: number | null
          prompted_odometer: number | null
          raw: Json
          status: string
          tag: string
          telematics_odometer: number | null
          transaction_time: string
          truck_id: number | null
          updated_at: string
          uuid: string
          vehicle_name: string
          vin: string
        }
        Insert: {
          amount?: number
          card_last_four?: string | null
          description?: string
          discount?: number | null
          driver_id?: number | null
          driver_name?: string
          fuel_type?: string
          gallons?: number | null
          id?: never
          imported_at?: string
          merchant?: string
          merchant_category?: string
          merchant_city?: string
          merchant_state?: string
          merchant_zip?: string
          net_of_discount?: number | null
          posted_date?: string | null
          price_per_gallon?: number | null
          prompted_odometer?: number | null
          raw?: Json
          status?: string
          tag?: string
          telematics_odometer?: number | null
          transaction_time: string
          truck_id?: number | null
          updated_at?: string
          uuid: string
          vehicle_name?: string
          vin?: string
        }
        Update: {
          amount?: number
          card_last_four?: string | null
          description?: string
          discount?: number | null
          driver_id?: number | null
          driver_name?: string
          fuel_type?: string
          gallons?: number | null
          id?: never
          imported_at?: string
          merchant?: string
          merchant_category?: string
          merchant_city?: string
          merchant_state?: string
          merchant_zip?: string
          net_of_discount?: number | null
          posted_date?: string | null
          price_per_gallon?: number | null
          prompted_odometer?: number | null
          raw?: Json
          status?: string
          tag?: string
          telematics_odometer?: number | null
          transaction_time?: string
          truck_id?: number | null
          updated_at?: string
          uuid?: string
          vehicle_name?: string
          vin?: string
        }
        Relationships: [
          {
            foreignKeyName: "fuel_transactions_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fuel_transactions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      gl_monthly: {
        Row: {
          account: string
          amount: number
          grp: string
          id: number
          month: string
          source: string
          updated_at: string
        }
        Insert: {
          account: string
          amount: number
          grp: string
          id?: never
          month: string
          source?: string
          updated_at?: string
        }
        Update: {
          account?: string
          amount?: number
          grp?: string
          id?: never
          month?: string
          source?: string
          updated_at?: string
        }
        Relationships: []
      }
      invoice_payments: {
        Row: {
          amount: number
          created_at: string
          id: number
          invoice_id: number
          method: string
          notes: string | null
          received_at: string
          recorded_by: string | null
          reference: string | null
        }
        Insert: {
          amount: number
          created_at?: string
          id?: never
          invoice_id: number
          method?: string
          notes?: string | null
          received_at?: string
          recorded_by?: string | null
          reference?: string | null
        }
        Update: {
          amount?: number
          created_at?: string
          id?: never
          invoice_id?: number
          method?: string
          notes?: string | null
          received_at?: string
          recorded_by?: string | null
          reference?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoice_payments_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_payments_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          paid_at: string | null
          qbo_balance: number | null
          qbo_doc_number: string | null
          qbo_id: string | null
          qbo_synced_at: string | null
          sent_at: string | null
          sent_to: string | null
          source: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        Insert: {
          created_at?: string
          customer_id: number
          due_date?: string | null
          id?: never
          invoice_date?: string
          invoice_number: string
          paid_at?: string | null
          qbo_balance?: number | null
          qbo_doc_number?: string | null
          qbo_id?: string | null
          qbo_synced_at?: string | null
          sent_at?: string | null
          sent_to?: string | null
          source?: string
          status?: Database["public"]["Enums"]["invoice_status"]
          total?: number
        }
        Update: {
          created_at?: string
          customer_id?: number
          due_date?: string | null
          id?: never
          invoice_date?: string
          invoice_number?: string
          paid_at?: string | null
          qbo_balance?: number | null
          qbo_doc_number?: string | null
          qbo_id?: string | null
          qbo_synced_at?: string | null
          sent_at?: string | null
          sent_to?: string | null
          source?: string
          status?: Database["public"]["Enums"]["invoice_status"]
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      llm_budget: {
        Row: {
          id: number
          monthly_cap_cents: number
          updated_at: string
        }
        Insert: {
          id?: number
          monthly_cap_cents?: number
          updated_at?: string
        }
        Update: {
          id?: number
          monthly_cap_cents?: number
          updated_at?: string
        }
        Relationships: []
      }
      llm_spend_daily: {
        Row: {
          cents_spent: number
          day: string
          provider: string
          request_count: number
        }
        Insert: {
          cents_spent?: number
          day: string
          provider: string
          request_count?: number
        }
        Update: {
          cents_spent?: number
          day?: string
          provider?: string
          request_count?: number
        }
        Relationships: []
      }
      load_stops: {
        Row: {
          address: string
          facility: string
          id: number
          load_id: number
          notes: string
          reference: string
          seq: number
          stop_time: string | null
          stop_type: string
        }
        Insert: {
          address?: string
          facility?: string
          id?: never
          load_id: number
          notes?: string
          reference?: string
          seq?: number
          stop_time?: string | null
          stop_type: string
        }
        Update: {
          address?: string
          facility?: string
          id?: never
          load_id?: number
          notes?: string
          reference?: string
          seq?: number
          stop_time?: string | null
          stop_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "load_stops_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
        ]
      }
      loads: {
        Row: {
          awaiting_paperwork: boolean
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          awaiting_paperwork?: boolean
          cancel_reason?: string
          created_at?: string
          customer_id: number
          delivery_address?: string
          delivery_number?: string
          delivery_time?: string | null
          driver_id?: number | null
          empty_miles?: number
          equipment_type?: string
          id?: never
          invoice_id?: number | null
          load_number: string
          miles?: number
          notes?: string
          pickup_address?: string
          pickup_number?: string
          pickup_time?: string | null
          rate?: number
          reference_number?: string
          special_terms?: string
          status?: Database["public"]["Enums"]["load_status"]
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          awaiting_paperwork?: boolean
          cancel_reason?: string
          created_at?: string
          customer_id?: number
          delivery_address?: string
          delivery_number?: string
          delivery_time?: string | null
          driver_id?: number | null
          empty_miles?: number
          equipment_type?: string
          id?: never
          invoice_id?: number | null
          load_number?: string
          miles?: number
          notes?: string
          pickup_address?: string
          pickup_number?: string
          pickup_time?: string | null
          rate?: number
          reference_number?: string
          special_terms?: string
          status?: Database["public"]["Enums"]["load_status"]
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "loads_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_trailer_id_fkey"
            columns: ["trailer_id"]
            isOneToOne: false
            referencedRelation: "trailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loads_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_records: {
        Row: {
          cost: number
          created_at: string
          date_completed: string | null
          description: string
          equipment_type: Database["public"]["Enums"]["equipment_type"]
          id: number
          invoice_ref: string
          is_planned: boolean
          needs_review: boolean
          odometer: number | null
          pm_program_id: number | null
          scheduled_date: string | null
          service_type: Database["public"]["Enums"]["maintenance_service_type"]
          source: string
          status: Database["public"]["Enums"]["maintenance_status"]
          technician_shop: string
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
          vendor_id: number | null
        }
        Insert: {
          cost?: number
          created_at?: string
          date_completed?: string | null
          description?: string
          equipment_type: Database["public"]["Enums"]["equipment_type"]
          id?: never
          invoice_ref?: string
          is_planned?: boolean
          needs_review?: boolean
          odometer?: number | null
          pm_program_id?: number | null
          scheduled_date?: string | null
          service_type?: Database["public"]["Enums"]["maintenance_service_type"]
          source?: string
          status?: Database["public"]["Enums"]["maintenance_status"]
          technician_shop?: string
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
          vendor_id?: number | null
        }
        Update: {
          cost?: number
          created_at?: string
          date_completed?: string | null
          description?: string
          equipment_type?: Database["public"]["Enums"]["equipment_type"]
          id?: never
          invoice_ref?: string
          is_planned?: boolean
          needs_review?: boolean
          odometer?: number | null
          pm_program_id?: number | null
          scheduled_date?: string | null
          service_type?: Database["public"]["Enums"]["maintenance_service_type"]
          source?: string
          status?: Database["public"]["Enums"]["maintenance_status"]
          technician_shop?: string
          trailer_id?: number | null
          truck_id?: number | null
          updated_at?: string
          vendor_id?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "maintenance_records_pm_program_id_fkey"
            columns: ["pm_program_id"]
            isOneToOne: false
            referencedRelation: "pm_programs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_records_trailer_id_fkey"
            columns: ["trailer_id"]
            isOneToOne: false
            referencedRelation: "trailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_records_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "maintenance_records_vendor_id_fkey"
            columns: ["vendor_id"]
            isOneToOne: false
            referencedRelation: "maintenance_vendors"
            referencedColumns: ["id"]
          },
        ]
      }
      maintenance_vendors: {
        Row: {
          city: string
          created_at: string
          id: number
          is_active: boolean
          name: string
          notes: string
          phone: string
          specialty: string
          state: string
          updated_at: string
        }
        Insert: {
          city?: string
          created_at?: string
          id?: never
          is_active?: boolean
          name: string
          notes?: string
          phone?: string
          specialty?: string
          state?: string
          updated_at?: string
        }
        Update: {
          city?: string
          created_at?: string
          id?: never
          is_active?: boolean
          name?: string
          notes?: string
          phone?: string
          specialty?: string
          state?: string
          updated_at?: string
        }
        Relationships: []
      }
      playbook_metrics: {
        Row: {
          category: string
          definition: string
          name: string
          number: number
          owner_role: string
          source: string
          status: string
          target: string
          updated_at: string
        }
        Insert: {
          category?: string
          definition?: string
          name: string
          number: number
          owner_role?: string
          source?: string
          status?: string
          target?: string
          updated_at?: string
        }
        Update: {
          category?: string
          definition?: string
          name?: string
          number?: number
          owner_role?: string
          source?: string
          status?: string
          target?: string
          updated_at?: string
        }
        Relationships: []
      }
      pm_programs: {
        Row: {
          applies_to: string
          created_at: string
          id: number
          interval_days: number | null
          interval_miles: number | null
          is_active: boolean
          name: string
          notes: string
          service_type: Database["public"]["Enums"]["maintenance_service_type"]
          updated_at: string
        }
        Insert: {
          applies_to?: string
          created_at?: string
          id?: never
          interval_days?: number | null
          interval_miles?: number | null
          is_active?: boolean
          name: string
          notes?: string
          service_type?: Database["public"]["Enums"]["maintenance_service_type"]
          updated_at?: string
        }
        Update: {
          applies_to?: string
          created_at?: string
          id?: never
          interval_days?: number | null
          interval_miles?: number | null
          is_active?: boolean
          name?: string
          notes?: string
          service_type?: Database["public"]["Enums"]["maintenance_service_type"]
          updated_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          full_name: string
          id: string
          is_active: boolean
          role: Database["public"]["Enums"]["user_role"]
          username: string
        }
        Insert: {
          created_at?: string
          full_name?: string
          id: string
          is_active?: boolean
          role?: Database["public"]["Enums"]["user_role"]
          username: string
        }
        Update: {
          created_at?: string
          full_name?: string
          id?: string
          is_active?: boolean
          role?: Database["public"]["Enums"]["user_role"]
          username?: string
        }
        Relationships: []
      }
      push_devices: {
        Row: {
          id: number
          platform: string
          token: string
          updated_at: string
          user_id: string
        }
        Insert: {
          id?: never
          platform: string
          token: string
          updated_at?: string
          user_id: string
        }
        Update: {
          id?: never
          platform?: string
          token?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "push_devices_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      qbo_connection: {
        Row: {
          access_expires_at: string
          access_token: string
          connected_at: string
          id: number
          oauth_state: string | null
          realm_id: string
          refresh_expires_at: string
          refresh_token: string
        }
        Insert: {
          access_expires_at: string
          access_token: string
          connected_at?: string
          id?: number
          oauth_state?: string | null
          realm_id: string
          refresh_expires_at: string
          refresh_token: string
        }
        Update: {
          access_expires_at?: string
          access_token?: string
          connected_at?: string
          id?: number
          oauth_state?: string | null
          realm_id?: string
          refresh_expires_at?: string
          refresh_token?: string
        }
        Relationships: []
      }
      qbo_sync_state: {
        Row: {
          backfilled: boolean
          id: number
          last_cdc: string | null
          last_error: string | null
          last_pnl_at: string | null
          last_pull_at: string | null
          last_result: Json | null
        }
        Insert: {
          backfilled?: boolean
          id?: number
          last_cdc?: string | null
          last_error?: string | null
          last_pnl_at?: string | null
          last_pull_at?: string | null
          last_result?: Json | null
        }
        Update: {
          backfilled?: boolean
          id?: number
          last_cdc?: string | null
          last_error?: string | null
          last_pnl_at?: string | null
          last_pull_at?: string | null
          last_result?: Json | null
        }
        Relationships: []
      }
      quote_requests: {
        Row: {
          company: string
          contact_name: string
          created_at: string
          dest_city: string
          dest_state: string
          dest_zip: string
          email: string
          equipment: string
          id: number
          notes: string
          origin_city: string
          origin_state: string
          origin_zip: string
          phone: string
          pickup_date: string | null
          status: string
        }
        Insert: {
          company?: string
          contact_name: string
          created_at?: string
          dest_city?: string
          dest_state?: string
          dest_zip?: string
          email?: string
          equipment?: string
          id?: never
          notes?: string
          origin_city?: string
          origin_state?: string
          origin_zip?: string
          phone?: string
          pickup_date?: string | null
          status?: string
        }
        Update: {
          company?: string
          contact_name?: string
          created_at?: string
          dest_city?: string
          dest_state?: string
          dest_zip?: string
          email?: string
          equipment?: string
          id?: never
          notes?: string
          origin_city?: string
          origin_state?: string
          origin_zip?: string
          phone?: string
          pickup_date?: string | null
          status?: string
        }
        Relationships: []
      }
      rate_limit_events: {
        Row: {
          action: string
          created_at: string
          id: number
          user_id: string
        }
        Insert: {
          action: string
          created_at?: string
          id?: never
          user_id: string
        }
        Update: {
          action?: string
          created_at?: string
          id?: never
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rate_limit_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      safety_csa: {
        Row: {
          alert: boolean
          basic: string
          measure: number | null
          percentile: number | null
          updated_at: string
        }
        Insert: {
          alert?: boolean
          basic: string
          measure?: number | null
          percentile?: number | null
          updated_at?: string
        }
        Update: {
          alert?: boolean
          basic?: string
          measure?: number | null
          percentile?: number | null
          updated_at?: string
        }
        Relationships: []
      }
      safety_events: {
        Row: {
          claim_amount: number
          created_at: string
          created_by: string | null
          csa_basic: string
          description: string
          driver_id: number | null
          event_date: string
          event_type: string
          id: number
          location: string
          out_of_service: boolean
          preventable: boolean
          severity: string
          status: string
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          claim_amount?: number
          created_at?: string
          created_by?: string | null
          csa_basic?: string
          description?: string
          driver_id?: number | null
          event_date: string
          event_type: string
          id?: never
          location?: string
          out_of_service?: boolean
          preventable?: boolean
          severity?: string
          status?: string
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          claim_amount?: number
          created_at?: string
          created_by?: string | null
          csa_basic?: string
          description?: string
          driver_id?: number | null
          event_date?: string
          event_type?: string
          id?: never
          location?: string
          out_of_service?: boolean
          preventable?: boolean
          severity?: string
          status?: string
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "safety_events_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "safety_events_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "safety_events_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      toll_transactions: {
        Row: {
          account_name: string
          account_number: number | null
          bill_to_account_name: string
          bill_to_account_number: number | null
          billing_agency_code: string
          device_number: string
          dispute_status: string
          entry_date_time: string | null
          entry_plaza_code: string
          entry_plaza_name: string
          exit_date_time: string | null
          exit_plaza_code: string
          exit_plaza_name: string
          id: number
          imported_at: string
          invoice_date_time: string | null
          plate_number: string
          post_date_time: string | null
          raw: Json
          read_type: string
          toll_agency_name: string
          toll_agency_state: string
          toll_category: string
          toll_charge: number
          toll_class: string
          toll_id: string
          truck_id: number | null
          updated_at: string
          vehicle_number: string
        }
        Insert: {
          account_name?: string
          account_number?: number | null
          bill_to_account_name?: string
          bill_to_account_number?: number | null
          billing_agency_code?: string
          device_number?: string
          dispute_status?: string
          entry_date_time?: string | null
          entry_plaza_code?: string
          entry_plaza_name?: string
          exit_date_time?: string | null
          exit_plaza_code?: string
          exit_plaza_name?: string
          id?: never
          imported_at?: string
          invoice_date_time?: string | null
          plate_number?: string
          post_date_time?: string | null
          raw?: Json
          read_type?: string
          toll_agency_name?: string
          toll_agency_state?: string
          toll_category?: string
          toll_charge?: number
          toll_class?: string
          toll_id: string
          truck_id?: number | null
          updated_at?: string
          vehicle_number?: string
        }
        Update: {
          account_name?: string
          account_number?: number | null
          bill_to_account_name?: string
          bill_to_account_number?: number | null
          billing_agency_code?: string
          device_number?: string
          dispute_status?: string
          entry_date_time?: string | null
          entry_plaza_code?: string
          entry_plaza_name?: string
          exit_date_time?: string | null
          exit_plaza_code?: string
          exit_plaza_name?: string
          id?: never
          imported_at?: string
          invoice_date_time?: string | null
          plate_number?: string
          post_date_time?: string | null
          raw?: Json
          read_type?: string
          toll_agency_name?: string
          toll_agency_state?: string
          toll_category?: string
          toll_charge?: number
          toll_class?: string
          toll_id?: string
          truck_id?: number | null
          updated_at?: string
          vehicle_number?: string
        }
        Relationships: [
          {
            foreignKeyName: "toll_transactions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      trailers: {
        Row: {
          created_at: string
          enriched_at: string | null
          id: number
          in_service_date: string | null
          make: string
          model: string
          monthly_cost: number
          notes: string
          out_of_service_date: string | null
          plate_expiry: string | null
          plate_number: string
          status: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at: string
          vin: string
          year: number | null
        }
        Insert: {
          created_at?: string
          enriched_at?: string | null
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Update: {
          created_at?: string
          enriched_at?: string | null
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number?: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Relationships: []
      }
      trucks: {
        Row: {
          created_at: string
          enriched_at: string | null
          id: number
          in_service_date: string | null
          make: string
          model: string
          monthly_cost: number
          notes: string
          out_of_service_date: string | null
          plate_expiry: string | null
          plate_number: string
          status: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at: string
          vin: string
          year: number | null
        }
        Insert: {
          created_at?: string
          enriched_at?: string | null
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Update: {
          created_at?: string
          enriched_at?: string | null
          id?: never
          in_service_date?: string | null
          make?: string
          model?: string
          monthly_cost?: number
          notes?: string
          out_of_service_date?: string | null
          plate_expiry?: string | null
          plate_number?: string
          status?: Database["public"]["Enums"]["equipment_status"]
          unit_number?: string
          updated_at?: string
          vin?: string
          year?: number | null
        }
        Relationships: []
      }
      trux_actions: {
        Row: {
          args: Json
          confirmation_token: string
          created_at: string
          error: string | null
          executed_at: string | null
          expires_at: string
          id: string
          result: Json | null
          session_id: string
          status: string
          tool_name: string
          user_id: string
        }
        Insert: {
          args?: Json
          confirmation_token: string
          created_at?: string
          error?: string | null
          executed_at?: string | null
          expires_at?: string
          id?: string
          result?: Json | null
          session_id: string
          status?: string
          tool_name: string
          user_id: string
        }
        Update: {
          args?: Json
          confirmation_token?: string
          created_at?: string
          error?: string | null
          executed_at?: string | null
          expires_at?: string
          id?: string
          result?: Json | null
          session_id?: string
          status?: string
          tool_name?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_actions_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "trux_actions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_agent_audit: {
        Row: {
          args: Json | null
          created_at: string
          detail: string | null
          id: number
          session_id: string | null
          status: string | null
          tool_name: string
          user_id: string | null
        }
        Insert: {
          args?: Json | null
          created_at?: string
          detail?: string | null
          id?: never
          session_id?: string | null
          status?: string | null
          tool_name: string
          user_id?: string | null
        }
        Update: {
          args?: Json | null
          created_at?: string
          detail?: string | null
          id?: never
          session_id?: string | null
          status?: string | null
          tool_name?: string
          user_id?: string | null
        }
        Relationships: []
      }
      trux_inbox_log: {
        Row: {
          created_at: string
          detail: string | null
          from_email: string
          graph_conversation_id: string | null
          graph_message_id: string
          id: number
          retries: number
          session_id: string | null
          status: string
          subject: string | null
        }
        Insert: {
          created_at?: string
          detail?: string | null
          from_email: string
          graph_conversation_id?: string | null
          graph_message_id: string
          id?: never
          retries?: number
          session_id?: string | null
          status: string
          subject?: string | null
        }
        Update: {
          created_at?: string
          detail?: string | null
          from_email?: string
          graph_conversation_id?: string | null
          graph_message_id?: string
          id?: never
          retries?: number
          session_id?: string | null
          status?: string
          subject?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "trux_inbox_log_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_inbox_state: {
        Row: {
          id: number
          last_poll: string
        }
        Insert: {
          id?: number
          last_poll?: string
        }
        Update: {
          id?: number
          last_poll?: string
        }
        Relationships: []
      }
      trux_insights: {
        Row: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          notified_at: string | null
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }
        Insert: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          category: string
          dedup_key: string
          detail?: string
          entity_id?: number | null
          entity_type?: string
          first_seen?: string
          id?: never
          last_seen?: string
          notified_at?: string | null
          resolved_at?: string | null
          severity: string
          status?: string
          title: string
        }
        Update: {
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          category?: string
          dedup_key?: string
          detail?: string
          entity_id?: number | null
          entity_type?: string
          first_seen?: string
          id?: never
          last_seen?: string
          notified_at?: string | null
          resolved_at?: string | null
          severity?: string
          status?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_insights_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_messages: {
        Row: {
          content: string
          created_at: string
          id: number
          meta: Json
          role: string
          session_id: string
        }
        Insert: {
          content?: string
          created_at?: string
          id?: never
          meta?: Json
          role: string
          session_id: string
        }
        Update: {
          content?: string
          created_at?: string
          id?: never
          meta?: Json
          role?: string
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_messages_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "trux_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      trux_observations: {
        Row: {
          classification: string
          confidence: string
          created_at: string
          extracted: Json | null
          id: number
          matched_customer_id: number | null
          matched_load_id: number | null
          message_id: string
          received_at: string | null
          review_note: string
          reviewed: boolean
          sender_email: string
          sender_name: string
          subject: string
          summary: string
          would_action: string
          would_detail: string
        }
        Insert: {
          classification?: string
          confidence?: string
          created_at?: string
          extracted?: Json | null
          id?: never
          matched_customer_id?: number | null
          matched_load_id?: number | null
          message_id: string
          received_at?: string | null
          review_note?: string
          reviewed?: boolean
          sender_email?: string
          sender_name?: string
          subject?: string
          summary?: string
          would_action?: string
          would_detail?: string
        }
        Update: {
          classification?: string
          confidence?: string
          created_at?: string
          extracted?: Json | null
          id?: never
          matched_customer_id?: number | null
          matched_load_id?: number | null
          message_id?: string
          received_at?: string | null
          review_note?: string
          reviewed?: boolean
          sender_email?: string
          sender_name?: string
          subject?: string
          summary?: string
          would_action?: string
          would_detail?: string
        }
        Relationships: []
      }
      trux_sessions: {
        Row: {
          created_at: string
          id: string
          title: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trux_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vehicle_position_current: {
        Row: {
          accuracy_m: number | null
          driver_id: number
          heading_deg: number | null
          lat: number
          lng: number
          load_id: number | null
          recorded_at: string
          speed_mps: number | null
          truck_id: number | null
          updated_at: string
        }
        Insert: {
          accuracy_m?: number | null
          driver_id: number
          heading_deg?: number | null
          lat: number
          lng: number
          load_id?: number | null
          recorded_at: string
          speed_mps?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Update: {
          accuracy_m?: number | null
          driver_id?: number
          heading_deg?: number | null
          lat?: number
          lng?: number
          load_id?: number | null
          recorded_at?: string
          speed_mps?: number | null
          truck_id?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicle_position_current_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: true
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_position_current_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_position_current_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
        ]
      }
      vehicle_positions: {
        Row: {
          accuracy_m: number | null
          battery_pct: number | null
          driver_id: number
          heading_deg: number | null
          id: number
          lat: number
          lng: number
          load_id: number | null
          received_at: string
          recorded_at: string
          source: string
          speed_mps: number | null
          truck_id: number | null
          user_id: string
        }
        Insert: {
          accuracy_m?: number | null
          battery_pct?: number | null
          driver_id: number
          heading_deg?: number | null
          id?: never
          lat: number
          lng: number
          load_id?: number | null
          received_at?: string
          recorded_at: string
          source?: string
          speed_mps?: number | null
          truck_id?: number | null
          user_id: string
        }
        Update: {
          accuracy_m?: number | null
          battery_pct?: number | null
          driver_id?: number
          heading_deg?: number | null
          id?: never
          lat?: number
          lng?: number
          load_id?: number | null
          received_at?: string
          recorded_at?: string
          source?: string
          speed_mps?: number | null
          truck_id?: number | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vehicle_positions_driver_id_fkey"
            columns: ["driver_id"]
            isOneToOne: false
            referencedRelation: "drivers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_load_id_fkey"
            columns: ["load_id"]
            isOneToOne: false
            referencedRelation: "loads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_truck_id_fkey"
            columns: ["truck_id"]
            isOneToOne: false
            referencedRelation: "trucks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vehicle_positions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      watchdog_heartbeats: {
        Row: {
          detail: string
          last_seen: string
          source: string
        }
        Insert: {
          detail?: string
          last_seen?: string
          source: string
        }
        Update: {
          detail?: string
          last_seen?: string
          source?: string
        }
        Relationships: []
      }
      watchdog_incidents: {
        Row: {
          check_name: string
          detail: string
          id: number
          opened_at: string
          remediation_count: number
          resolved_at: string | null
          severity: string
          status: string
          updated_at: string
        }
        Insert: {
          check_name: string
          detail?: string
          id?: never
          opened_at?: string
          remediation_count?: number
          resolved_at?: string | null
          severity?: string
          status?: string
          updated_at?: string
        }
        Update: {
          check_name?: string
          detail?: string
          id?: never
          opened_at?: string
          remediation_count?: number
          resolved_at?: string | null
          severity?: string
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
      watchdog_remediations: {
        Row: {
          action_key: string
          after_state: Json | null
          approval_token: string | null
          before_state: Json | null
          check_name: string
          created_at: string
          decided_at: string | null
          detail: string
          expires_at: string | null
          id: number
          incident_id: number | null
          params: Json
          proposed_at: string
          revert_of: number | null
          status: string
          tier: string
        }
        Insert: {
          action_key: string
          after_state?: Json | null
          approval_token?: string | null
          before_state?: Json | null
          check_name: string
          created_at?: string
          decided_at?: string | null
          detail?: string
          expires_at?: string | null
          id?: never
          incident_id?: number | null
          params?: Json
          proposed_at?: string
          revert_of?: number | null
          status?: string
          tier: string
        }
        Update: {
          action_key?: string
          after_state?: Json | null
          approval_token?: string | null
          before_state?: Json | null
          check_name?: string
          created_at?: string
          decided_at?: string | null
          detail?: string
          expires_at?: string | null
          id?: never
          incident_id?: number | null
          params?: Json
          proposed_at?: string
          revert_of?: number | null
          status?: string
          tier?: string
        }
        Relationships: [
          {
            foreignKeyName: "watchdog_remediations_incident_id_fkey"
            columns: ["incident_id"]
            isOneToOne: false
            referencedRelation: "watchdog_incidents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "watchdog_remediations_revert_of_fkey"
            columns: ["revert_of"]
            isOneToOne: false
            referencedRelation: "watchdog_remediations"
            referencedColumns: ["id"]
          },
        ]
      }
      watchdog_state: {
        Row: {
          check_name: string
          detail: string | null
          last_alert: string | null
          last_change: string | null
          status: string
          updated_at: string
        }
        Insert: {
          check_name: string
          detail?: string | null
          last_alert?: string | null
          last_change?: string | null
          status: string
          updated_at?: string
        }
        Update: {
          check_name?: string
          detail?: string | null
          last_alert?: string | null
          last_change?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      acct_aging: {
        Args: never
        Returns: {
          current_due: number
          customer_id: number
          customer_name: string
          d1_30: number
          d31_60: number
          d61_90: number
          d90_plus: number
          invoice_count: number
          total: number
        }[]
      }
      acct_margin_monthly: {
        Args: { p_months?: number }
        Returns: {
          fuel: number
          maintenance: number
          margin: number
          month: string
          operating_ratio: number
          revenue: number
          tolls: number
        }[]
      }
      acct_revenue_by_customer: {
        Args: { p_days?: number }
        Returns: {
          avg_days_to_pay: number
          billed: number
          customer_id: number
          customer_name: string
          invoice_count: number
          open_balance: number
          past_due: number
          share_pct: number
        }[]
      }
      acct_revenue_monthly: {
        Args: { p_months?: number }
        Returns: {
          billed: number
          collected: number
          month: string
        }[]
      }
      acct_summary: { Args: never; Returns: Json }
      acct_unbilled_loads: {
        Args: never
        Returns: {
          customer_id: number
          customer_name: string
          days_unbilled: number
          delivered_at: string
          load_id: number
          load_number: string
          rate: number
        }[]
      }
      acknowledge_insight: {
        Args: { p_id: number }
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          notified_at: string | null
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }
        SetofOptions: {
          from: "*"
          to: "trux_insights"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      apply_customer_enrichment: {
        Args: {
          p_customer_id: number
          p_fields: Json
          p_model?: string
          p_source_document_id?: number
        }
        Returns: number
      }
      apply_equipment_enrichment: {
        Args: {
          p_equipment_id: number
          p_equipment_type: string
          p_fields: Json
          p_model?: string
          p_source_document_id?: number
        }
        Returns: Json
      }
      ar_aging: {
        Args: never
        Returns: {
          company_name: string
          customer_id: number
          d0_30: number
          d31_60: number
          d61_90: number
          d90_plus: number
          invoices: number
          outstanding: number
        }[]
      }
      assert_no_double_booking: {
        Args: {
          p_driver_id: number
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
          p_truck_id: number
        }
        Returns: undefined
      }
      bs_upsert: { Args: { p: Json }; Returns: undefined }
      budget_variance: {
        Args: { p_end: string; p_start: string }
        Returns: {
          actual: number
          budget: number
          line: string
          variance: number
          variance_pct: number
        }[]
      }
      cancel_load: {
        Args: { p_load_id: number; p_reason?: string }
        Returns: {
          awaiting_paperwork: boolean
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      carrier_safety_latest: { Args: never; Returns: Json }
      cashflow_forecast: {
        Args: { p_weeks?: number }
        Returns: {
          cumulative_net: number
          expected_in: number
          expected_out: number
          net: number
          week_label: string
          week_number: number
          week_start: string
        }[]
      }
      change_load_status: {
        Args: {
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
        }
        Returns: {
          awaiting_paperwork: boolean
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      check_rate_limit: {
        Args: { p_action: string; p_max: number; p_window?: string }
        Returns: boolean
      }
      claim_doc_search: {
        Args: never
        Returns: {
          entity_type: string
          id: number
          query: string
        }[]
      }
      company_scorecard: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      complete_doc_search: {
        Args: { p_error?: string; p_id: number; p_results?: Json }
        Returns: undefined
      }
      create_invoice: {
        Args: {
          p_customer_id: number
          p_due_date?: string
          p_load_ids: number[]
        }
        Returns: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          paid_at: string | null
          qbo_balance: number | null
          qbo_doc_number: string | null
          qbo_id: string | null
          qbo_synced_at: string | null
          sent_at: string | null
          sent_to: string | null
          source: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        SetofOptions: {
          from: "*"
          to: "invoices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_work_order_draft: { Args: { p: Json }; Returns: number }
      current_odometer: { Args: { p_truck_id: number }; Returns: number }
      customer_pay_profile: {
        Args: never
        Returns: {
          avg_days: number
          customer_id: number
          paid_count: number
        }[]
      }
      dashboard_summary: { Args: never; Returns: Json }
      delete_customer: { Args: { p_id: number }; Returns: undefined }
      delete_invoice_payment: {
        Args: { p_payment_id: number }
        Returns: undefined
      }
      drive_create_share: {
        Args: { p_expires_at?: string; p_file_id: number }
        Returns: string
      }
      drive_delete: { Args: { p_ids: number[] }; Returns: string[] }
      drive_ensure_path: {
        Args: { p_drive: string; p_path: string }
        Returns: undefined
      }
      drive_move: {
        Args: { p_ids: number[]; p_new_parent: string }
        Returns: undefined
      }
      drive_rename: {
        Args: { p_id: number; p_new_name: string }
        Returns: undefined
      }
      driver_add_document: {
        Args: {
          p_content_type?: string
          p_doc_type?: string
          p_filename: string
          p_load_id: number
          p_size_bytes?: number
          p_storage_path: string
        }
        Returns: Json
      }
      driver_change_load_status: {
        Args: {
          p_load_id: number
          p_status: Database["public"]["Enums"]["load_status"]
        }
        Returns: Json
      }
      driver_get_load: { Args: { p_load_id: number }; Returns: Json }
      driver_list_documents: { Args: { p_load_id: number }; Returns: Json }
      driver_load_dto: { Args: { p_load_id: number }; Returns: Json }
      driver_my_loads: { Args: never; Returns: Json }
      driver_owns_load: { Args: { p_load_id: number }; Returns: boolean }
      driver_owns_load_path: { Args: { p_name: string }; Returns: boolean }
      driver_set_duty: {
        Args: { p_on_duty: boolean }
        Returns: {
          driver_id: number
          is_on_duty: boolean
          on_duty_since: string | null
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "driver_duty"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      duplicate_customer_groups: {
        Args: never
        Returns: {
          members: Json
          norm_key: string
        }[]
      }
      eld_fleet_live: { Args: never; Returns: Json }
      eld_link_vehicles: { Args: never; Returns: number }
      enqueue_doc_search: {
        Args: { p_entity_type?: string; p_query: string }
        Returns: number
      }
      equipment_conflicts: {
        Args: never
        Returns: {
          created_at: string
          equipment_id: number
          equipment_type: string
          field: string
          log_id: number
          model: string
          new_value: string
          old_value: string
          source_document_id: number
          source_filename: string
          unit_number: string
        }[]
      }
      fleet_odometers: {
        Args: never
        Returns: {
          odometer: number
          reading_date: string
          truck_id: number
          unit_number: string
        }[]
      }
      fleet_positions_snapshot: { Args: never; Returns: Json }
      fmcsa_rating_label: { Args: { p_rating: string }; Returns: string }
      fmcsa_record: {
        Args: { p_basics?: Json; p_snapshot: Json }
        Returns: Json
      }
      fuel_by_truck: {
        Args: { p_end: string; p_start: string }
        Returns: {
          gallons: number
          spend: number
          transactions: number
          truck_id: number
          unit_number: string
        }[]
      }
      fuel_efficiency: {
        Args: { p_end: string; p_start: string }
        Returns: {
          driver_id: number
          driver_name: string
          fuel_cost_per_mile: number
          fuel_spend: number
          gallons: number
          loads: number
          miles: number
          mpg: number
        }[]
      }
      fuel_ifta_summary: {
        Args: { p_end: string; p_start: string }
        Returns: {
          gallons: number
          jurisdiction: string
          spend: number
          transactions: number
        }[]
      }
      gl_breakeven_monthly: {
        Args: { p_months?: number }
        Returns: {
          cushion_pct: number
          miles: number
          month: string
          revenue: number
          rpm_actual: number
          rpm_breakeven: number
          total_costs: number
        }[]
      }
      gl_cfo_snapshot: { Args: never; Returns: Json }
      gl_expense_breakdown: {
        Args: { p_months?: number }
        Returns: {
          account: string
          grp: string
          monthly_avg: number
          pct_of_revenue: number
          total: number
        }[]
      }
      gl_pnl_monthly: {
        Args: { p_months?: number }
        Returns: {
          cogs: number
          gross_margin_pct: number
          gross_profit: number
          income: number
          month: string
          net_income: number
          net_margin_pct: number
          operating_ratio: number
          opex: number
          other_net: number
        }[]
      }
      gl_upsert_monthly: { Args: { p_rows: Json }; Returns: number }
      global_search: { Args: { q: string }; Returns: Json }
      import_fuel_transactions: { Args: { p_rows: Json }; Returns: Json }
      import_toll_transactions: { Args: { p_rows: Json }; Returns: Json }
      ingest_vehicle_positions: { Args: { p_points: Json }; Returns: Json }
      invoice_balance: {
        Args: { i: Database["public"]["Tables"]["invoices"]["Row"] }
        Returns: number
      }
      list_invoice_payments: {
        Args: { p_invoice_id: number }
        Returns: {
          amount: number
          created_at: string
          id: number
          invoice_id: number
          method: string
          notes: string | null
          received_at: string
          recorded_by: string | null
          reference: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "invoice_payments"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      llm_reserve_spend: {
        Args: { p_cents: number; p_provider: string }
        Returns: boolean
      }
      loads_missing_pod: {
        Args: { p_days?: number }
        Returns: {
          customer: string
          delivered_at: string
          delivery_number: string
          load_id: number
          load_number: string
          pickup_number: string
          reference_number: string
          status: string
        }[]
      }
      loads_missing_pod_summary: { Args: { p_days?: number }; Returns: Json }
      log_observation: { Args: { p: Json }; Returns: number }
      maintenance_alerts: {
        Args: never
        Returns: {
          category: string
          detail: string
          due_date: string
          equipment_type: string
          kind: string
          label: string
          severity: string
          unit_id: number
          unit_number: string
        }[]
      }
      maintenance_by_truck: {
        Args: { p_end: string; p_start: string }
        Returns: {
          cpm: number
          events: number
          planned_cost: number
          reactive_cost: number
          total_cost: number
          truck_id: number
          unit_number: string
          window_miles: number
        }[]
      }
      maintenance_by_vendor: {
        Args: { p_end: string; p_start: string }
        Returns: {
          events: number
          planned_cost: number
          total_cost: number
          vendor: string
        }[]
      }
      maintenance_cpm: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      maintenance_due: {
        Args: never
        Returns: {
          current_odometer: number
          days_remaining: number
          days_since: number
          due_status: string
          equipment_type: string
          interval_days: number
          interval_miles: number
          last_service_date: string
          last_service_odometer: number
          miles_remaining: number
          miles_since: number
          program_id: number
          program_name: string
          service_type: string
          unit_id: number
          unit_number: string
        }[]
      }
      maintenance_summary: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      match_document_embeddings: {
        Args: { p_count?: number; p_embedding: string; p_entity_type?: string }
        Returns: {
          content: string
          doc_type: string
          document_id: number
          drive_file_id: number
          entity_id: number
          entity_type: string
          filename: string
          similarity: number
        }[]
      }
      match_extraction_examples: {
        Args: { p_count?: number; p_document_id: number }
        Returns: {
          company_name: string
          customer_id: number
          document_id: number
          fields: Json
          similarity: number
        }[]
      }
      merge_customers: {
        Args: { p_dupe: number; p_keep: number }
        Returns: Json
      }
      my_driver_id: { Args: never; Returns: number }
      my_role: {
        Args: never
        Returns: Database["public"]["Enums"]["user_role"]
      }
      next_invoice_number: { Args: never; Returns: string }
      next_load_number: { Args: never; Returns: string }
      normalize_company_name: { Args: { p: string }; Returns: string }
      playbook_coverage: { Args: never; Returns: Json }
      playbook_metrics_list: {
        Args: { p_owner?: string; p_search?: string; p_status?: string }
        Returns: {
          category: string
          definition: string
          name: string
          number: number
          owner_role: string
          source: string
          status: string
          target: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "playbook_metrics"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      pnl_summary: { Args: { p_end: string; p_start: string }; Returns: Json }
      pod_archive_candidate: {
        Args: { p_delivery?: string; p_pickup?: string; p_ref: string }
        Returns: string
      }
      pod_archive_candidate_file: {
        Args: { p_load_id: number }
        Returns: {
          content_type: string
          drive_file_id: number
          filename: string
          storage_path: string
        }[]
      }
      qbo_mark_voided: { Args: { p_qbo_ids: Json }; Returns: number }
      qbo_status: { Args: never; Returns: Json }
      qbo_upsert_invoices: { Args: { p_rows: Json }; Returns: Json }
      record_invoice_payment: {
        Args: {
          p_amount: number
          p_invoice_id: number
          p_method?: string
          p_notes?: string
          p_received_at?: string
          p_reference?: string
        }
        Returns: Json
      }
      replace_load_stops: {
        Args: { p_load_id: number; p_stops?: Json }
        Returns: {
          address: string
          facility: string
          id: number
          load_id: number
          notes: string
          reference: string
          seq: number
          stop_time: string | null
          stop_type: string
        }[]
        SetofOptions: {
          from: "*"
          to: "load_stops"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      resolve_equipment_conflict: {
        Args: { p_action: string; p_log_id: number }
        Returns: undefined
      }
      revenue_forecast: {
        Args: { p_weeks?: number }
        Returns: {
          basis: string
          forecast_revenue: number
          last_year_revenue: number
          loads_per_truck: number
          trailing_avg: number
          week_label: string
          week_number: number
          week_start: string
        }[]
      }
      safety_summary: {
        Args: { p_end: string; p_start: string }
        Returns: Json
      }
      sentinel_open_summary: { Args: never; Returns: Json }
      sentinel_scan: { Args: never; Returns: Json }
      sentinel_take_alerts: {
        Args: never
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          notified_at: string | null
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }[]
        SetofOptions: {
          from: "*"
          to: "trux_insights"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      set_invoice_status: {
        Args: {
          p_invoice_id: number
          p_status: Database["public"]["Enums"]["invoice_status"]
        }
        Returns: {
          created_at: string
          customer_id: number
          due_date: string | null
          id: number
          invoice_date: string
          invoice_number: string
          paid_at: string | null
          qbo_balance: number | null
          qbo_doc_number: string | null
          qbo_id: string | null
          qbo_synced_at: string | null
          sent_at: string | null
          sent_to: string | null
          source: string
          status: Database["public"]["Enums"]["invoice_status"]
          total: number
        }
        SetofOptions: {
          from: "*"
          to: "invoices"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_load_paperwork: {
        Args: { p_awaiting: boolean; p_id: number }
        Returns: undefined
      }
      slow_pay_risk: {
        Args: never
        Returns: {
          avg_days: number
          customer: string
          customer_id: number
          due_date: string
          invoice_date: string
          invoice_id: number
          invoice_number: string
          predicted_days_late: number
          predicted_pay_date: string
          risk: string
          total: number
        }[]
      }
      toll_by_agency: {
        Args: { p_end: string; p_start: string }
        Returns: {
          agency: string
          jurisdiction: string
          spend: number
          tolls: number
        }[]
      }
      toll_by_truck: {
        Args: { p_end: string; p_start: string }
        Returns: {
          spend: number
          tolls: number
          truck_id: number
          unit_number: string
          violations: number
        }[]
      }
      trux_first_monday: { Args: { p_year: number }; Returns: string }
      trux_insights_feed: {
        Args: { p_include_resolved?: boolean }
        Returns: {
          acknowledged_at: string | null
          acknowledged_by: string | null
          category: string
          dedup_key: string
          detail: string
          entity_id: number | null
          entity_type: string
          first_seen: string
          id: number
          last_seen: string
          notified_at: string | null
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }[]
        SetofOptions: {
          from: "*"
          to: "trux_insights"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      trux_query: { Args: { p_sql: string }; Returns: Json }
      trux_week_end: { Args: { d: string }; Returns: string }
      trux_week_label: { Args: { d: string }; Returns: string }
      trux_week_number: { Args: { d: string }; Returns: number }
      trux_week_range: {
        Args: { p_week: number; p_year: number }
        Returns: {
          week_end: string
          week_start: string
        }[]
      }
      trux_week_start: { Args: { d: string }; Returns: string }
      trux_week_year: { Args: { d: string }; Returns: number }
      uncancel_load: {
        Args: { p_load_id: number }
        Returns: {
          awaiting_paperwork: boolean
          cancel_reason: string
          created_at: string
          customer_id: number
          delivery_address: string
          delivery_number: string
          delivery_time: string | null
          driver_id: number | null
          empty_miles: number
          equipment_type: string
          id: number
          invoice_id: number | null
          load_number: string
          miles: number
          notes: string
          pickup_address: string
          pickup_number: string
          pickup_time: string | null
          rate: number
          reference_number: string
          special_terms: string
          status: Database["public"]["Enums"]["load_status"]
          trailer_id: number | null
          truck_id: number | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "loads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_doc_embeddings: {
        Args: {
          p_chunks: Json
          p_document_id: number
          p_entity_id: number
          p_entity_type: string
        }
        Returns: number
      }
      upsert_drive_embeddings: {
        Args: { p_chunks: Json; p_drive_file_id: number }
        Returns: number
      }
      void_invoice: { Args: { p_invoice_id: number }; Returns: undefined }
      watchdog_action_count: {
        Args: { p_action_key: string; p_since_minutes: number }
        Returns: number
      }
      watchdog_db_probes: {
        Args: { p_backup_stale_hours?: number; p_gps_stale_min?: number }
        Returns: Json
      }
      watchdog_incident_feed: {
        Args: { p_limit?: number }
        Returns: {
          check_name: string
          detail: string
          id: number
          opened_at: string
          remediation_count: number
          resolved_at: string | null
          severity: string
          status: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "watchdog_incidents"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      weekly_report: { Args: { p_week_of?: string }; Returns: Json }
    }
    Enums: {
      driver_status: "active" | "inactive" | "terminated"
      equipment_status: "available" | "in_use" | "maintenance" | "retired"
      equipment_type: "truck" | "trailer"
      invoice_status: "draft" | "sent" | "paid" | "void"
      load_status:
        | "pending"
        | "assigned"
        | "in_transit"
        | "delivered"
        | "completed"
        | "billed"
        | "cancelled"
      maintenance_service_type:
        | "pm_service"
        | "oil_lube"
        | "tires"
        | "brakes"
        | "engine"
        | "drivetrain"
        | "electrical"
        | "cooling"
        | "aftertreatment"
        | "dot_inspection"
        | "bodywork"
        | "roadside"
        | "other"
      maintenance_status:
        | "scheduled"
        | "in_progress"
        | "completed"
        | "cancelled"
      user_role:
        | "admin"
        | "dispatcher"
        | "driver"
        | "accountant"
        | "maintenance"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  storage: {
    Tables: {
      buckets: {
        Row: {
          allowed_mime_types: string[] | null
          avif_autodetection: boolean | null
          created_at: string | null
          file_size_limit: number | null
          id: string
          name: string
          owner: string | null
          owner_id: string | null
          public: boolean | null
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string | null
        }
        Insert: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id: string
          name: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Update: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id?: string
          name?: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Relationships: []
      }
      buckets_analytics: {
        Row: {
          created_at: string
          deleted_at: string | null
          format: string
          id: string
          name: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      buckets_vectors: {
        Row: {
          created_at: string
          id: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      iceberg_namespaces: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          metadata: Json
          name: string
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          metadata?: Json
          name: string
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          metadata?: Json
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_namespaces_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
        ]
      }
      iceberg_tables: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          location: string
          name: string
          namespace_id: string
          remote_table_id: string | null
          shard_id: string | null
          shard_key: string | null
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          location: string
          name: string
          namespace_id: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          location?: string
          name?: string
          namespace_id?: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_tables_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "iceberg_tables_namespace_id_fkey"
            columns: ["namespace_id"]
            isOneToOne: false
            referencedRelation: "iceberg_namespaces"
            referencedColumns: ["id"]
          },
        ]
      }
      migrations: {
        Row: {
          executed_at: string | null
          hash: string
          id: number
          name: string
        }
        Insert: {
          executed_at?: string | null
          hash: string
          id: number
          name: string
        }
        Update: {
          executed_at?: string | null
          hash?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      objects: {
        Row: {
          bucket_id: string | null
          created_at: string | null
          id: string
          last_accessed_at: string | null
          metadata: Json | null
          name: string | null
          owner: string | null
          owner_id: string | null
          path_tokens: string[] | null
          updated_at: string | null
          user_metadata: Json | null
          version: string | null
        }
        Insert: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Update: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          in_progress_size: number
          key: string
          metadata: Json | null
          owner_id: string | null
          upload_signature: string
          user_metadata: Json | null
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id: string
          in_progress_size?: number
          key: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature: string
          user_metadata?: Json | null
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          in_progress_size?: number
          key?: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature?: string
          user_metadata?: Json | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads_parts: {
        Row: {
          bucket_id: string
          created_at: string
          etag: string
          id: string
          key: string
          owner_id: string | null
          part_number: number
          size: number
          upload_id: string
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          etag: string
          id?: string
          key: string
          owner_id?: string | null
          part_number: number
          size?: number
          upload_id: string
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          etag?: string
          id?: string
          key?: string
          owner_id?: string | null
          part_number?: number
          size?: number
          upload_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_parts_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "s3_multipart_uploads_parts_upload_id_fkey"
            columns: ["upload_id"]
            isOneToOne: false
            referencedRelation: "s3_multipart_uploads"
            referencedColumns: ["id"]
          },
        ]
      }
      vector_indexes: {
        Row: {
          bucket_id: string
          created_at: string
          data_type: string
          dimension: number
          distance_metric: string
          id: string
          metadata_configuration: Json | null
          name: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          data_type: string
          dimension: number
          distance_metric: string
          id?: string
          metadata_configuration?: Json | null
          name: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          data_type?: string
          dimension?: number
          distance_metric?: string
          id?: string
          metadata_configuration?: Json | null
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vector_indexes_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_vectors"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      allow_any_operation: {
        Args: { expected_operations: string[] }
        Returns: boolean
      }
      allow_only_operation: {
        Args: { expected_operation: string }
        Returns: boolean
      }
      can_insert_object: {
        Args: { bucketid: string; metadata: Json; name: string; owner: string }
        Returns: undefined
      }
      extension: { Args: { name: string }; Returns: string }
      filename: { Args: { name: string }; Returns: string }
      foldername: { Args: { name: string }; Returns: string[] }
      get_common_prefix: {
        Args: { p_delimiter: string; p_key: string; p_prefix: string }
        Returns: string
      }
      get_size_by_bucket: {
        Args: never
        Returns: {
          bucket_id: string
          size: number
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
          prefix_param: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          _bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_token?: string
          prefix_param: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      operation: { Args: never; Returns: string }
      search: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_by_timestamp: {
        Args: {
          p_bucket_id: string
          p_level: number
          p_limit: number
          p_prefix: string
          p_sort_column: string
          p_sort_column_after: string
          p_sort_order: string
          p_start_after: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v2: {
        Args: {
          bucket_name: string
          levels?: number
          limits?: number
          prefix: string
          sort_column?: string
          sort_column_after?: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
    }
    Enums: {
      buckettype: "STANDARD" | "ANALYTICS" | "VECTOR"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      driver_status: ["active", "inactive", "terminated"],
      equipment_status: ["available", "in_use", "maintenance", "retired"],
      equipment_type: ["truck", "trailer"],
      invoice_status: ["draft", "sent", "paid", "void"],
      load_status: [
        "pending",
        "assigned",
        "in_transit",
        "delivered",
        "completed",
        "billed",
        "cancelled",
      ],
      maintenance_service_type: [
        "pm_service",
        "oil_lube",
        "tires",
        "brakes",
        "engine",
        "drivetrain",
        "electrical",
        "cooling",
        "aftertreatment",
        "dot_inspection",
        "bodywork",
        "roadside",
        "other",
      ],
      maintenance_status: [
        "scheduled",
        "in_progress",
        "completed",
        "cancelled",
      ],
      user_role: ["admin", "dispatcher", "driver", "accountant", "maintenance"],
    },
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS", "VECTOR"],
    },
  },
} as const

